// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const spirv = @import("spirv.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const semantic = @import("semantic.zig");
const preprocessor = @import("preprocessor.zig");
const compact_ids = @import("compact_ids.zig");
const opt = @import("compact_ids_passes.zig");
const loop_phi = @import("loop_counter_phi.zig");
const fold_ec = @import("fold_extract_construct.zig");
const inline_mb = @import("inline_multiblock.zig");

pub const Stage = enum { vertex, fragment, compute, geometry, tessellation_control, tessellation_evaluation, mesh, task, raygen, closesthit, miss, intersection, anyhit, callable };
pub const SPIRVVersion = enum { @"1.0", @"1.1", @"1.2", @"1.3", @"1.4", @"1.5", @"1.6" };

/// Memory layout rule for a UBO/SSBO block.
/// - std140: classic OpenGL/Vulkan UBO layout (16-byte array stride, vec3 padded to vec4).
/// - std430: SSBO layout (tight vec3, tight array stride, but vectors still aligned to component count).
/// - scalar: GL_EXT_scalar_block_layout — every type aligned to its scalar component, no rounding.
pub const LayoutKind = enum { std140, std430, scalar };

fn spirv_versionOrdinal(v: SPIRVVersion) u32 {
    return switch (v) {
        .@"1.0" => 0,
        .@"1.1" => 1,
        .@"1.2" => 2,
        .@"1.3" => 3,
        .@"1.4" => 4,
        .@"1.5" => 5,
        .@"1.6" => 6,
    };
}

pub fn generate(
    alloc: std.mem.Allocator,
    module: *const ir.Module,
    stage: Stage,
    spirv_version: SPIRVVersion,
    glsl_version: u32,
    is_essl: bool,
    default_layout: LayoutKind,
) error{OutOfMemory, CodegenFailed}![]const u32 {
    return generateInternal(alloc, module, stage, spirv_version, glsl_version, is_essl, default_layout, false);
}

pub fn generateNoOpt(
    alloc: std.mem.Allocator,
    module: *const ir.Module,
    stage: Stage,
    spirv_version: SPIRVVersion,
    glsl_version: u32,
    is_essl: bool,
    default_layout: LayoutKind,
) error{OutOfMemory, CodegenFailed}![]const u32 {
    return generateInternal(alloc, module, stage, spirv_version, glsl_version, is_essl, default_layout, true);
}

fn generateInternal(
    alloc: std.mem.Allocator,
    module: *const ir.Module,
    stage: Stage,
    spirv_version: SPIRVVersion,
    glsl_version: u32,
    is_essl: bool,
    default_layout: LayoutKind,
    no_opt: bool,
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
        .emitted_storage_image_types = .{},
        .emitted_array_types = .{},
        .emitted_tensor_types = .{},
        .emitted_array_stride = .{},
        .emitted_struct_layout = .{},
        .emitted_named_types = .{},
        .emitted_interface_named_types = .{},
        .emitted_ptr_types = .{},
        .emitted_constants = .{},
        .constant_alias = .{},
        .emitted_func_types = .{},
        .emitted_struct_layouts = .{},
        .layout_visited = .{},
        .default_row_major = false,
        .default_layout = default_layout,
        .ptr_storage_class = .{},
        .storage_image_format_by_ptr = .{},
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
        .glsl_std_450_id = 0,
        .access_chain_cache = .{},
        .interface_bool_ptrs = .{},
        .codegen_pure_cache = .{},
        .spec_const_component_ids = .{},
    };
    defer cg.deinit();

    // Mesh/task shaders require SPIR-V 1.4+
    if ((stage == .mesh or stage == .task or stage == .raygen or stage == .closesthit or stage == .miss or stage == .intersection or stage == .anyhit or stage == .callable) and spirv_versionOrdinal(spirv_version) < spirv_versionOrdinal(.@"1.4")) {
        return error.CodegenFailed;
    }

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

    const raw = try cg.words.toOwnedSlice(alloc);
    if (no_opt) return raw;

    // NOTE: raw is the unoptimized SPIR-V output. generateNoOpt() returns this directly.
    // === Streamlined optimization pipeline ===
    // Single pass of each optimization category. Removes repeated iterations
    // that provided diminishing returns for compute shaders.

    // Early cleanup: merge access chains + DCE
    const merged = opt.mergeAccessChains(alloc, raw) catch raw;
    if (merged.ptr != raw.ptr) alloc.free(raw);
    const dce = opt.deadCodeElim(alloc, merged) catch return merged;
    if (dce.ptr != merged.ptr) alloc.free(merged);
    const no_wrapper = opt.elimTrivialEntryPoint(alloc, dce) catch return dce;
    if (no_wrapper.ptr != dce.ptr) alloc.free(dce);
    const loop_elim = opt.deadLoopElim(alloc, no_wrapper) catch return no_wrapper;
    if (loop_elim.ptr != no_wrapper.ptr) alloc.free(no_wrapper);
    const no_unreachable = opt.elimUnreachableCalls(alloc, loop_elim) catch loop_elim;
    if (no_unreachable.ptr != loop_elim.ptr) alloc.free(loop_elim);

    // Inlining (single pass with fixup)
    var inlined = opt.inlineTrivialFuncs(alloc, no_unreachable) catch return no_unreachable;
    if (inlined.ptr != no_unreachable.ptr) alloc.free(no_unreachable);
    {
        const var_fixed = opt.moveVarToEntry(alloc, inlined) catch inlined;
        if (var_fixed.ptr != inlined.ptr) alloc.free(inlined);
        const dce2 = opt.deadCodeElim(alloc, var_fixed) catch var_fixed;
        if (dce2.ptr != var_fixed.ptr) alloc.free(var_fixed);
        inlined = compact_ids.compactIds(alloc, dce2) catch dce2;
        if (inlined.ptr != dce2.ptr) alloc.free(dce2);
    }

    // Dead function removal
    const no_dead_calls = opt.elimDeadVoidCalls(alloc, inlined) catch return inlined;
    if (no_dead_calls.ptr != inlined.ptr) alloc.free(inlined);
    const no_dead_funcs = opt.elimDeadFunctions(alloc, no_dead_calls) catch return no_dead_calls;
    if (no_dead_funcs.ptr != no_dead_calls.ptr) alloc.free(no_dead_calls);

    // Loop counter to Phi + branch merge Phi
    const phi = loop_phi.loopCounterToPhi(alloc, no_dead_funcs) catch return no_dead_funcs;
    if (phi.ptr != no_dead_funcs.ptr) alloc.free(no_dead_funcs);
    const bphi = opt.branchMergePhi(alloc, phi) catch return phi;
    if (bphi.ptr != phi.ptr) alloc.free(phi);
    const simpl_phi = opt.simplifyTrivialPhi(alloc, bphi) catch bphi;
    if (simpl_phi.ptr != bphi.ptr) alloc.free(bphi);

    // Store forwarding + block merging
    const rse = opt.redundantStoreElim(alloc, simpl_phi) catch return simpl_phi;
    if (rse.ptr != simpl_phi.ptr) alloc.free(simpl_phi);
    const blk1 = opt.mergeBlocks(alloc, rse) catch return rse;
    if (blk1.ptr != rse.ptr) alloc.free(rse);
    const blk2 = opt.mergeNonEmptyBlocks(alloc, blk1) catch return blk1;
    if (blk2.ptr != blk1.ptr) alloc.free(blk1);

    // Hoist invariant access chains
    const hoisted = opt.hoistInvariantACs(alloc, blk2) catch return blk2;
    if (hoisted.ptr != blk2.ptr) alloc.free(blk2);
    const hoisted_dce = opt.deadCodeElim(alloc, hoisted) catch return hoisted;
    if (hoisted_dce.ptr != hoisted.ptr) alloc.free(hoisted);

    // Multi-block inlining
    const mb_inlined = inline_mb.inlineMultiBlock(alloc, hoisted_dce) catch return hoisted_dce;
    if (mb_inlined.ptr != hoisted_dce.ptr) alloc.free(hoisted_dce);
    const mb_merged = opt.mergeBlocks(alloc, mb_inlined) catch mb_inlined;
    if (mb_merged.ptr != mb_inlined.ptr) alloc.free(mb_inlined);
    const mb_merged2 = opt.mergeNonEmptyBlocks(alloc, mb_merged) catch return mb_merged;
    if (mb_merged2.ptr != mb_merged.ptr) alloc.free(mb_merged);
    const mb_dce = opt.deadCodeElim(alloc, mb_merged2) catch return mb_merged2;
    if (mb_dce.ptr != mb_merged2.ptr) alloc.free(mb_merged2);

    // Type dedup
    const deduped = opt.dedupStructTypes(alloc, mb_dce) catch return mb_dce;
    if (deduped.ptr != mb_dce.ptr) alloc.free(mb_dce);

    // Arithmetic simplification chain
    const neg1 = opt.elimSelfRefArithmetic(alloc, deduped) catch return deduped;
    if (neg1.ptr != deduped.ptr) alloc.free(deduped);
    const neg2 = opt.eliminateDoubleNegate(alloc, neg1) catch return neg1;
    if (neg2.ptr != neg1.ptr) alloc.free(neg1);
    const neg3 = opt.foldNegateIntoAddSub(alloc, neg2) catch return neg2;
    if (neg3.ptr != neg2.ptr) alloc.free(neg2);
    const algebrad = opt.algebraicSimpl(alloc, neg3) catch return neg3;
    if (algebrad.ptr != neg3.ptr) alloc.free(neg3);
    const cf = opt.constFold(alloc, algebrad) catch return algebrad;
    if (cf.ptr != algebrad.ptr) alloc.free(algebrad);
    const folded = opt.foldSelect(alloc, cf) catch return cf;
    if (folded.ptr != cf.ptr) alloc.free(cf);

    // Control flow optimization
    const folded_br = opt.foldConstBranches(alloc, folded) catch folded;
    if (folded_br.ptr != folded.ptr) alloc.free(folded);
    const elim_blks = opt.elimUnreachableBlocks(alloc, folded_br) catch folded_br;
    if (elim_blks.ptr != folded_br.ptr) alloc.free(folded_br);
    const phi2 = opt.simplifyTrivialPhi(alloc, elim_blks) catch elim_blks;
    if (phi2.ptr != elim_blks.ptr) alloc.free(elim_blks);
    const compacted = compact_ids.compactIds(alloc, phi2) catch return phi2;
    if (compacted.ptr != phi2.ptr) alloc.free(phi2);

    // Memory optimization
    const no_rle = opt.elimRedundantLoads(alloc, compacted) catch return compacted;
    if (no_rle.ptr != compacted.ptr) alloc.free(compacted);
    const no_dup = opt.cseWithinBlocks(alloc, no_rle) catch return no_rle;
    if (no_dup.ptr != no_rle.ptr) alloc.free(no_rle);

    // Composite optimization
    const cce = opt.foldConstCompositeExtract(alloc, no_dup) catch no_dup;
    if (cce.ptr != no_dup.ptr) alloc.free(no_dup);
    const ce = opt.foldCompositeExtract(alloc, cce) catch return cce;
    if (ce.ptr != cce.ptr) alloc.free(cce);
    const sh = opt.foldShuffleFromComposite(alloc, ce) catch ce;
    if (sh.ptr != ce.ptr) alloc.free(ce);
    const ecs = fold_ec.foldExtractConstructToShuffle(alloc, sh) catch sh;
    if (ecs.ptr != sh.ptr) alloc.free(sh);
    const no_id_sh = opt.elimIdentityShuffle(alloc, ecs) catch return ecs;
    if (no_id_sh.ptr != ecs.ptr) alloc.free(ecs);

    // Variable optimization
    const no_uninit = opt.elimUninitVars(alloc, no_id_sh) catch return no_id_sh;
    if (no_uninit.ptr != no_id_sh.ptr) alloc.free(no_id_sh);
    const const_fwd = opt.constStoreForward(alloc, no_uninit) catch return no_uninit;
    if (const_fwd.ptr != no_uninit.ptr) alloc.free(no_uninit);
    const fixed_early = opt.fixEarlyAccessVars(alloc, const_fwd) catch const_fwd;
    if (fixed_early.ptr != const_fwd.ptr) alloc.free(const_fwd);

    // Store-to-composite + store-forward
    const scattered = opt.scatterStoreToComposite(alloc, fixed_early) catch return fixed_early;
    if (scattered.ptr != fixed_early.ptr) alloc.free(fixed_early);
    const forwarded = opt.storeForwardExtract(alloc, scattered) catch return scattered;
    if (forwarded.ptr != scattered.ptr) alloc.free(scattered);

    // Final cleanup
    const no_dead_stores = opt.elimDeadVarStores(alloc, forwarded) catch forwarded;
    if (no_dead_stores.ptr != forwarded.ptr) alloc.free(forwarded);
    const final_dce = opt.deadCodeElim(alloc, no_dead_stores) catch return no_dead_stores;
    if (final_dce.ptr != no_dead_stores.ptr) alloc.free(no_dead_stores);
    const retargeted = opt.retargetEmptyBlocks(alloc, final_dce) catch return final_dce;
    if (retargeted.ptr != final_dce.ptr) alloc.free(final_dce);
    const final_cse = opt.cseWithinBlocks(alloc, retargeted) catch return retargeted;
    if (final_cse.ptr != retargeted.ptr) alloc.free(retargeted);
    const final_dce2 = opt.deadCodeElim(alloc, final_cse) catch return final_cse;
    if (final_dce2.ptr != final_cse.ptr) alloc.free(final_cse);
    const no_id_stores = opt.elimIdentityStores(alloc, final_dce2) catch return final_dce2;
    if (no_id_stores.ptr != final_dce2.ptr) alloc.free(final_dce2);
    // copyMemoryOpt disabled: replaces Load+Store with OpCopyMemory but produces
    // undefined IDs when DCE later eliminates AccessChain sources. The pass also
    // causes hangs on some shaders. Not worth the risk for saving one instruction.
    const final_dce3 = opt.deadCodeElim(alloc, no_id_stores) catch return no_id_stores;
    if (final_dce3.ptr != no_id_stores.ptr) alloc.free(no_id_stores);
    const compacted2 = compact_ids.compactIds(alloc, final_dce3) catch return final_dce3;
    if (compacted2.ptr != final_dce3.ptr) alloc.free(final_dce3);

    // Import + global cleanup (single pass)
    const no_imports = opt.elimUnusedImports(alloc, compacted2) catch return compacted2;
    if (no_imports.ptr != compacted2.ptr) alloc.free(compacted2);
    const no_imports_dce = opt.deadCodeElim(alloc, no_imports) catch return no_imports;
    if (no_imports_dce.ptr != no_imports.ptr) alloc.free(no_imports);
    const compacted3 = compact_ids.compactIds(alloc, no_imports_dce) catch return no_imports_dce;
    if (compacted3.ptr != no_imports_dce.ptr) alloc.free(no_imports_dce);
    const gu = opt.elimUnusedGlobals(alloc, compacted3) catch return compacted3;
    if (gu.ptr != compacted3.ptr) alloc.free(compacted3);
    const gu_dce = opt.deadCodeElim(alloc, gu) catch gu;
    if (gu_dce.ptr != gu.ptr) alloc.free(gu);
    const gu_strip = opt.stripDeadDebugInfo(alloc, gu_dce) catch gu_dce;
    if (gu_strip.ptr != gu_dce.ptr) alloc.free(gu_dce);
    const gu_dce2 = opt.deadCodeElim(alloc, gu_strip) catch gu_strip;
    if (gu_dce2.ptr != gu_strip.ptr) alloc.free(gu_strip);
    const gu_compact = compact_ids.compactIds(alloc, gu_dce2) catch return gu_dce2;
    if (gu_compact.ptr != gu_dce2.ptr) alloc.free(gu_dce2);

    // Final type dedup
    const deduped_arr = opt.dedupArrayTypes(alloc, gu_compact) catch return gu_compact;
    if (deduped_arr.ptr != gu_compact.ptr) alloc.free(gu_compact);
    const deduped_struct = opt.dedupStructTypes(alloc, deduped_arr) catch return deduped_arr;
    if (deduped_struct.ptr != deduped_arr.ptr) alloc.free(deduped_arr);
    const deduped_ptr = opt.dedupPointerTypes(alloc, deduped_struct) catch return deduped_struct;
    if (deduped_ptr.ptr != deduped_struct.ptr) alloc.free(deduped_struct);
    const deduped_func = opt.dedupFunctionTypes(alloc, deduped_ptr) catch deduped_ptr;
    if (deduped_func.ptr != deduped_ptr.ptr) alloc.free(deduped_ptr);
    const tail_dce = opt.deadCodeElim(alloc, deduped_func) catch return deduped_func;
    if (tail_dce.ptr != deduped_func.ptr) alloc.free(deduped_func);
    const result = compact_ids.compactIds(alloc, tail_dce) catch return tail_dce;
    if (result.ptr != tail_dce.ptr) alloc.free(tail_dce);
    return result;

}

/// Dedup key for an OpTypeArray in `emitted_array_types`. Folds the effective
/// block layout so an `element[size]` array gets DISTINCT type ids under
/// std140 vs std430 — each needs its own ArrayStride (e.g. float[2] → 16 vs 4).
/// `layout == null` (function-local / non-block arrays carry no ArrayStride)
/// reproduces the original injective `(base_id << 32) | size` key exactly, so
/// non-block arrays keep their previous dedup behavior unchanged. Both
/// `ensureType`'s `.array` branch and `emitArrayStrideRecursive` MUST agree on
/// this formula, or the stride lookup misses the type it decorated.
fn arrayCacheKey(base_id: u32, size: u32, layout: ?LayoutKind) u64 {
    const base = (@as(u64, base_id) << 32) | @as(u64, size);
    const disc: u64 = if (layout) |k| @as(u64, @intFromEnum(k)) + 1 else 0;
    return base ^ (disc *% 0x9E3779B97F4A7C15);
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
    in_interface_block: bool = false, // true when emitting struct members for Block-decorated types
    // Effective block layout while emitting a Block-decorated struct's member
    // types. Folded into the array-type dedup key so a float[2] member of an
    // std140 block (ArrayStride 16) and of an std430 block (ArrayStride 4) get
    // DISTINCT array types — each carrying its own ArrayStride — instead of
    // sharing one. null outside a Block (local/function arrays carry no stride
    // and dedup freely). See ensureType's .array branch + emitArrayStrideRecursive.
    array_layout_ctx: ?LayoutKind = null,
    next_id: u32,
    emitted_types: std.AutoHashMapUnmanaged(u32, u32), // @intFromEnum(ty) -> type_id
    // Format-aware dedup for STORAGE images (#183): keyed by
    // `(@intFromEnum(ty) << 8) | @intFromEnum(fmt)` so two `image2D`s with
    // distinct `layout(rgbaN)` qualifiers get distinct OpTypeImage ids.
    // The format-blind `emitted_types` would collapse them and drop the second
    // image's Format. Sampled images (always Unknown format) keep using
    // `emitted_types` — only storage images route here.
    emitted_storage_image_types: std.AutoHashMapUnmanaged(u64, u32),
    emitted_array_types: std.AutoHashMapUnmanaged(u64, u32), // hash -> type_id
    emitted_tensor_types: std.AutoHashMapUnmanaged(u64, u32), // hash -> type_id
    emitted_array_stride: std.AutoHashMapUnmanaged(u32, void), // array type_ids with ArrayStride already emitted
    emitted_struct_layout: std.AutoHashMapUnmanaged(u32, void), // struct type_ids with layout decorations already emitted
    emitted_named_types: std.StringHashMapUnmanaged(u32), // struct name -> type_id
    emitted_interface_named_types: std.StringHashMapUnmanaged(u32), // struct name -> interface type_id (bool->uint)
    emitted_ptr_types: std.AutoHashMapUnmanaged(u64, u32), // (type_key << 32 | sc) -> ptr_type_id
    emitted_constants: std.AutoHashMapUnmanaged(u64, u32), // (type_id << 32 | value) -> const_id
    constant_alias: std.AutoHashMapUnmanaged(u32, u32), // IR result_id -> actual constant_id (dedup)
    emitted_func_types: std.AutoHashMapUnmanaged(u64, u32), // hash(ret+params) -> func_type_id
    emitted_struct_layouts: std.AutoHashMapUnmanaged(u64, u32), // hash(member_types) -> struct_type_id
    layout_visited: std.AutoHashMapUnmanaged(u32, void), // struct type_ids currently being laid out (cycle detection)
    default_row_major: bool, // current block-level matrix layout
    default_layout: LayoutKind, // default block layout when no std140/std430 qualifier is present
    ptr_storage_class: std.AutoHashMapUnmanaged(u32, ir.SPIRVStorageClass), // result_id -> storage class for pointers
    // #183: per-storage-image-global result_id -> declared `layout(rgbaN)` format.
    // Threads each variable's own format into loads of that image so the format
    // survives even when several images share the same GLSL enum (the
    // format-blind `emitted_types` would otherwise reuse the first one's type).
    storage_image_format_by_ptr: std.AutoHashMapUnmanaged(u32, ast.ImageFormat),
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
    // Maps each sampler type (keyed by the ast.Type enum tag) to the inner
    // OpTypeImage id (Sampled=1) that sits inside its OpTypeSampledImage. Used by
    // extract_image (OpImage) to pick the result type matching the source
    // sampler — so distinct Dim/Arrayed/sampled-format samplers never collide or
    // reference an undefined id. Populated by the sampler arms of ensureType
    // (#188). Keyed on the tag (not the union) because ast.Type's array/struct
    // variants carry slices that AutoHashMap cannot hash; all sampler tags are
    // void-payload, so the tag is a lossless key for them.
    sampled_image_inner_by_type: std.AutoHashMapUnmanaged(std.meta.Tag(ast.Type), u32) = .{},
    glsl_std_450_id: u32,
    access_chain_cache: std.AutoHashMapUnmanaged(u64, u32), // (base_id << 32 | index_id) -> result_id, cleared per function
    interface_bool_ptrs: std.AutoHashMapUnmanaged(u32, ast.Type), // ptr_id -> original AST type (bool/bvecN) for interface bool conversion
    codegen_pure_cache: std.AutoHashMapUnmanaged(u64, u32), // general pure op cache for codegen-level dedup
    // Map: composite spec-const result_id -> slice of per-scalar component ids
    // (one OpSpecConstant per scalar, each gets its own SpecId decoration).
    // Used by emitDecorations to emit `OpDecorate <component_id> SpecId <spec_id+i>`.
    // Slices are owned by this codegen and freed in deinit.
    spec_const_component_ids: std.AutoHashMapUnmanaged(u32, []const u32),

    fn deinit(self: *Codegen) void {
        self.emitted_types.deinit(self.alloc);
        self.emitted_storage_image_types.deinit(self.alloc);
        self.emitted_array_types.deinit(self.alloc);
        self.emitted_array_stride.deinit(self.alloc);
        self.emitted_struct_layout.deinit(self.alloc);
        self.emitted_named_types.deinit(self.alloc);
        self.emitted_interface_named_types.deinit(self.alloc);
        self.emitted_ptr_types.deinit(self.alloc);
        self.emitted_constants.deinit(self.alloc);
        self.constant_alias.deinit(self.alloc);
        self.emitted_func_types.deinit(self.alloc);
        self.emitted_struct_layouts.deinit(self.alloc);
        self.layout_visited.deinit(self.alloc);
        self.ptr_storage_class.deinit(self.alloc);
        self.storage_image_format_by_ptr.deinit(self.alloc);
        self.access_chain_cache.deinit(self.alloc);
        self.interface_bool_ptrs.deinit(self.alloc);
        self.codegen_pure_cache.deinit(self.alloc);
        self.sampled_image_inner_by_type.deinit(self.alloc);
        {
            var it = self.spec_const_component_ids.valueIterator();
            while (it.next()) |slice_ptr| {
                if (slice_ptr.*.len > 0) self.alloc.free(slice_ptr.*);
            }
            self.spec_const_component_ids.deinit(self.alloc);
        }
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

    /// Whether the module uses GL_EXT/NV_fragment_shader_barycentric, and if so
    /// whether the NV spelling was used (which only changes the OpExtension
    /// string — the capability and decorations are the KHR forms either way).
    const BarycentricUse = struct { used: bool = false, nv: bool = false };
    fn barycentricUsage(self: *Codegen) BarycentricUse {
        var bary = BarycentricUse{};
        for (self.module.globals) |global| {
            if (global.qualifier.is_pervertex_ext) bary.used = true;
            if (global.qualifier.is_pervertex_nv) {
                bary.used = true;
                bary.nv = true;
            }
            if (std.mem.eql(u8, global.name, "gl_BaryCoordEXT") or
                std.mem.eql(u8, global.name, "gl_BaryCoordNoPerspEXT")) bary.used = true;
            if (std.mem.eql(u8, global.name, "gl_BaryCoordNV") or
                std.mem.eql(u8, global.name, "gl_BaryCoordNoPerspNV")) {
                bary.used = true;
                bary.nv = true;
            }
        }
        return bary;
    }

    fn emitCapabilities(self: *Codegen) !void {
        // Always emit Shader capability
        try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
        try self.emitWord(@intFromEnum(spirv.Capability.shader));

        // Check if sample-related builtins are used → emit SampleRateShading capability
        var has_sample_builtins = false;
        for (self.module.globals) |global| {
            if (std.mem.eql(u8, global.name, "gl_SampleID") or
                std.mem.eql(u8, global.name, "gl_SamplePosition") or
                std.mem.eql(u8, global.name, "gl_SampleMaskIn") or
                std.mem.eql(u8, global.name, "gl_SampleMask")) {
                has_sample_builtins = true;
                break;
            }
        }
        if (has_sample_builtins) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.sample_rate_shading));
        }

        // interpolateAtCentroid/Sample/Offset (GLSL.std.450 76/77/78) require the
        // InterpolationFunction capability. The semantic analyzer sets this flag
        // when any of them is lowered.
        if (self.module.uses_interpolation_function) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.interpolation_function));
        }

        // textureGatherOffsets emits OpImageGather with the ConstOffsets image
        // operand, which requires the ImageGatherExtended capability. The
        // semantic analyzer sets this flag when any such gather is lowered.
        if (self.module.uses_image_gather_extended) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.image_gather_extended));
        }

        // Mesh/Task shader capabilities
        if (self.stage == .mesh or self.stage == .task) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.mesh_shading_ext));
        }
        if (self.stage == .raygen or self.stage == .closesthit or self.stage == .miss or
            self.stage == .intersection or self.stage == .anyhit or self.stage == .callable) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.ray_tracing_khr));
        }
        if (self.stage == .geometry) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.geometry));
        }
        if (self.stage == .tessellation_control or self.stage == .tessellation_evaluation) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.tessellation));
        }
        // Check if gl_Layer/gl_ViewportIndex are used — they need ShaderLayer/ShaderViewportIndex caps
        var has_layer = false;
        var has_viewport = false;
        var has_point_size = false;
        for (self.module.globals) |global| {
            if (std.mem.eql(u8, global.name, "gl_Layer")) has_layer = true;
            if (std.mem.eql(u8, global.name, "gl_ViewportIndex")) has_viewport = true;
            if (std.mem.eql(u8, global.name, "gl_PointSize")) has_point_size = true;
        }
        if (has_layer and self.stage != .geometry) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.shader_layer));
        }
        if (has_viewport and self.stage != .geometry) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.shader_viewport_index));
        }
        if (has_point_size) {
            if (self.stage == .geometry) {
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
                try self.emitWord(@intFromEnum(spirv.Capability.geometry_point_size));
            } else if (self.stage == .tessellation_control or self.stage == .tessellation_evaluation) {
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
                try self.emitWord(@intFromEnum(spirv.Capability.tessellation_point_size));
            }
        }

        // DrawParameters capability for gl_BaseVertex/gl_BaseInstance/gl_DrawID
        var has_draw_params = false;
        var has_device_group = false;
        var has_multi_view = false;
        var has_clip_dist = false;
        var has_cull_dist = false;
        for (self.module.globals) |global| {
            if (std.mem.eql(u8, global.name, "gl_BaseVertex") or
                std.mem.eql(u8, global.name, "gl_BaseInstance") or
                std.mem.eql(u8, global.name, "gl_DrawID")) has_draw_params = true;
            if (std.mem.eql(u8, global.name, "gl_DeviceIndex")) has_device_group = true;
            if (std.mem.eql(u8, global.name, "gl_ViewIndex")) has_multi_view = true;
            if (std.mem.eql(u8, global.name, "gl_ClipDistance")) has_clip_dist = true;
            if (std.mem.eql(u8, global.name, "gl_CullDistance")) has_cull_dist = true;
        }
        if (has_draw_params) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.draw_parameters));
        }
        if (has_device_group) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.device_group));
        }
        if (has_multi_view) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.multi_view));
        }
        if (has_clip_dist) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.clip_distance));
        }
        if (has_cull_dist) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.cull_distance));
        }
        // FragmentBarycentricKHR — GL_EXT/NV_fragment_shader_barycentric.
        if (self.barycentricUsage().used) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.fragment_barycentric_khr));
        }

        // Only emit additional capabilities if the module actually uses them
        var has_subgroup_vote = false;
        var has_group_non_uniform = false;
        var has_float_atomic = false;
        var has_input_attachment = false;
        var has_interlock = false;

        for (self.module.functions) |func| {
            for (func.body) |inst| {
                switch (inst.tag) {
                    .group_all, .group_any => has_subgroup_vote = true,
                    .group_non_uniform_elect => has_group_non_uniform = true,
                    .atomic_fadd => has_float_atomic = true,
                    .begin_invocation_interlock, .end_invocation_interlock => has_interlock = true,
                    else => {},
                }
            }
        }

        // Check globals for input attachment
        for (self.module.globals) |global| {
            if (global.layout) |layout| {
                if (layout.input_attachment_index != null) {
                    has_input_attachment = true;
                }
            }
        }

        // Check for specific image-related capabilities based on actual usage
        var has_image_query = false;
        var has_sampler1d = false;
        var has_image1d = false;
        var has_sampler_buffer = false;
        var has_derivative_control = false;
        var has_cube_array = false;
        var has_sampler2d_ms_array = false;

        for (self.module.functions) |func| {
            for (func.body) |inst| {
                switch (inst.tag) {
                    .image_query_size, .image_query_size_lod,
                    .image_query_levels, .image_query_samples,
                    .image_query_lod,
                    => has_image_query = true,
                    .derivative => has_derivative_control = true,
                    .fwidth => {
                        if (inst.operands.len > 1) {
                            if (inst.operands[0] == .literal_int and inst.operands[0].literal_int >= 1) {
                                has_derivative_control = true;
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        // Check global sampler types for type-specific capabilities
        var has_storage_image_ms = false;
        for (self.module.globals) |global| {
            var check_ty = global.ty;
            // Unwrap EVERY array level (arrays-of-arrays of samplers are legal):
            // the inner opaque type drives the required capability, and the
            // OpTypeImage is emitted regardless of array nesting depth. A
            // single-level unwrap left nested sampler arrays (e.g.
            // `sampler1D s[2][2]`) without their Sampled1D capability.
            while (check_ty == .array) check_ty = check_ty.array.base.*;
            switch (check_ty) {
                .sampler1d, .sampler1d_array, .sampler1d_shadow, .isampler1d, .isampler1d_array, .usampler1d, .usampler1d_array => has_sampler1d = true,
                .image1d, .iimage1d, .uimage1d => has_image1d = true,
                .sampler_buffer, .isampler_buffer, .usampler_buffer, .image_buffer, .iimage_buffer, .uimage_buffer => has_sampler_buffer = true,
                .sampler2d_ms_array, .isampler2d_ms_array, .usampler2d_ms_array, .image2d_ms_array => {
                    has_sampler2d_ms_array = true;
                    has_storage_image_ms = true;
                },
                .image2d_ms, .sampler2d_ms, .isampler2d_ms, .usampler2d_ms => has_storage_image_ms = true,
                .sampler_cube_array, .sampler_cube_array_shadow, .isampler_cube_array, .usampler_cube_array,
                .image_cube_array, .iimage_cube_array, .uimage_cube_array => has_cube_array = true,
                else => {},
            }
        }

        if (has_image_query) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.image_query));
        }
        if (has_sampler1d) {
            // Sampled 1D images require the Sampled1D capability (matches glslang).
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.sampled_1d));
        }
        if (has_image1d) {
            // Storage 1D images require the Image1D capability.
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.image_1d));
        }
        if (has_sampler_buffer) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.sampled_buffer));
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.image_buffer));
        }
        if (has_derivative_control) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.derivative_control));
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
        if (has_group_non_uniform) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.group_non_uniform));
        }
        if (has_float_atomic) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.atomic_float32_add_ext));
        }
        if (has_input_attachment) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.input_attachment));
        }
        if (has_interlock) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.fragment_shader_pixel_interlock_ext));
        }
        if (self.module.sample_interlock_ordered or self.module.sample_interlock_unordered) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.fragment_shader_sample_interlock_ext));
        }
        if (self.hasBufferReference()) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.physical_storage_buffer_addresses));
        }
        // Emit 8/16-bit type capabilities if needed
        var has_int8 = false;
        var has_int16 = false;
        var has_float16 = false;
        var has_float64 = false;
        for (self.module.globals) |global| {
            has_int8 = has_int8 or self.typeUsesInt8(global.ty);
            has_int16 = has_int16 or self.typeUsesInt16(global.ty);
            has_float16 = has_float16 or self.typeUsesFloat16(global.ty);
            has_float64 = has_float64 or self.typeUsesFloat64(global.ty);
        }
        // Also check struct members for 8/16-bit types
        var type_iter = self.module.types.iterator();
        while (type_iter.next()) |entry| {
            for (entry.value_ptr.members) |member| {
                has_int8 = has_int8 or self.typeUsesInt8(member.ty);
                has_int16 = has_int16 or self.typeUsesInt16(member.ty);
                has_float16 = has_float16 or self.typeUsesFloat16(member.ty);
                has_float64 = has_float64 or self.typeUsesFloat64(member.ty);
            }
        }
        // Also check function IR instructions for 8/16-bit types
        for (self.module.functions) |func| {
            for (func.body) |inst| {
                has_int8 = has_int8 or self.typeUsesInt8(inst.ty);
                has_int16 = has_int16 or self.typeUsesInt16(inst.ty);
                has_float16 = has_float16 or self.typeUsesFloat16(inst.ty);
                has_float64 = has_float64 or self.typeUsesFloat64(inst.ty);
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
        if (has_float64) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.float64));
        }
        // QCOM image processing capabilities
        if (self.module.uses_qcom_image_processing) {
            // Check which specific QCOM opcodes are used
            var has_box_filter = false;
            var has_block_match = false;
            var has_sample_weighted = false;
            for (self.module.functions) |func| {
                for (func.body) |inst| {
                    switch (inst.tag) {
                        .image_box_filter_qcom => has_box_filter = true,
                        .image_block_match_sad_qcom, .image_block_match_ssd_qcom => has_block_match = true,
                        .image_sample_weighted_qcom => has_sample_weighted = true,
                        else => {},
                    }
                }
            }
            if (has_sample_weighted) {
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
                try self.emitWord(@intFromEnum(spirv.Capability.texture_sample_weighted_qcom));
            }
            if (has_box_filter) {
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
                try self.emitWord(@intFromEnum(spirv.Capability.texture_box_filter_qcom));
            }
            if (has_block_match) {
                try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
                try self.emitWord(@intFromEnum(spirv.Capability.texture_block_match_qcom));
            }
        }
        // Ray query capabilities
        var has_ray_query_types = self.module.uses_ray_query;
        if (!has_ray_query_types) {
            for (self.module.globals) |global| {
                if (global.ty == .acceleration_structure_ext or global.ty == .ray_query_ext) {
                    has_ray_query_types = true;
                    break;
                }
            }
        }
        if (has_ray_query_types) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.ray_query_khr));
        }
        if (self.module.uses_ray_query_position_fetch) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.ray_query_position_fetch_khr));
        }
        // ARM tensor capability
        var needs_tensor_cap = self.module.uses_arm_tensors;
        if (!needs_tensor_cap) {
            for (self.module.globals) |global| {
                if (global.ty == .tensor_arm) { needs_tensor_cap = true; break; }
            }
        }
        if (needs_tensor_cap) {
            try self.emitWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.Capability)));
            try self.emitWord(@intFromEnum(spirv.Capability.tensors_arm));
        }
    }

    fn typeUsesFloat16(self: *Codegen, ty: ast.Type) bool {
        return switch (ty) {
            .float16, .f16vec2, .f16vec3, .f16vec4 => true,
            .array => |arr| self.typeUsesFloat16(arr.base.*),
            .tensor_arm => |ta| self.typeUsesFloat16(ta.element.*),
            else => false,
        };
    }
    fn typeUsesFloat64(self: *Codegen, ty: ast.Type) bool {
        return switch (ty) {
            .double => true,
            .array => |arr| self.typeUsesFloat64(arr.base.*),
            .tensor_arm => |ta| self.typeUsesFloat64(ta.element.*),
            else => false,
        };
    }
    fn isTextureType(self: *Codegen, ty: ast.Type) bool {
        return switch (ty) {
            .texture2d_plain, .texture3d_plain, .texture_cube_plain,
            .texture2d_array_plain, .texture2d_ms_plain,
            .sampler2d, .sampler2d_array, .sampler3d, .sampler1d,
            .sampler2d_ms, .sampler2d_ms_array, .sampler_buffer,
            .sampler2d_shadow, .sampler1d_shadow, .sampler_cube_shadow,
            .sampler2d_array_shadow, .sampler_cube_array_shadow,
            .sampler_cube, .sampler_cube_array, .sampler_plain,
            .image2d, .iimage2d, .uimage2d, .image1d, .iimage1d, .uimage1d,
            .image3d, .iimage3d, .uimage3d, .image_cube, .iimage_cube, .uimage_cube,
            .image2d_array, .iimage2d_array, .uimage2d_array,
            .image_cube_array, .iimage_cube_array, .uimage_cube_array,
            .image_buffer, .image2d_ms, .image2d_ms_array => true,
            .named => false, // struct types are not textures
            .array => |arr| self.isTextureType(arr.base.*),
            else => false,
        };
    }
    fn typeUsesInt8(self: *Codegen, ty: ast.Type) bool {
        return switch (ty) {
            .int8, .i8vec2, .i8vec3, .i8vec4, .uint8, .u8vec2, .u8vec3, .u8vec4 => true,
            .array => |arr| self.typeUsesInt8(arr.base.*),
            .tensor_arm => |ta| self.typeUsesInt8(ta.element.*),
            else => false,
        };
    }
    fn typeUsesInt16(self: *Codegen, ty: ast.Type) bool {
        return switch (ty) {
            .int16, .i16vec2, .i16vec3, .i16vec4, .uint16, .u16vec2, .u16vec3, .u16vec4 => true,
            .array => |arr| self.typeUsesInt16(arr.base.*),
            .tensor_arm => |ta| self.typeUsesInt16(ta.element.*),
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
        // QCOM image processing extension
        if (self.module.uses_qcom_image_processing) {
            const qcom_ext = "SPV_QCOM_image_processing";
            const qcom_wc: u16 = 1 + @as(u16, @intCast(std.math.divCeil(usize, qcom_ext.len + 1, 4) catch unreachable));
            try self.emitWord(spirv.encodeInstructionHeader(qcom_wc, @intFromEnum(spirv.Op.Extension)));
            const qcom_nw = std.math.divCeil(usize, qcom_ext.len + 1, 4) catch unreachable;
            const qcom_ew = try self.alloc.alloc(u32, qcom_nw);
            @memset(qcom_ew, 0);
            for (qcom_ext, 0..) |byte, idx| {
                const word_idx = idx / 4;
                const byte_idx = idx % 4;
                qcom_ew[word_idx] |= @as(u32, byte) << @intCast(byte_idx * 8);
            }
            for (qcom_ew) |w| try self.emitWord(w);
            self.alloc.free(qcom_ew);
        }
        // Ray query extensions
        var needs_rq_ext = self.module.uses_ray_query;
        if (!needs_rq_ext) {
            for (self.module.globals) |global| {
                if (global.ty == .acceleration_structure_ext or global.ty == .ray_query_ext) {
                    needs_rq_ext = true;
                    break;
                }
            }
        }
        if (needs_rq_ext) {
            const rq_ext = "SPV_KHR_ray_query";
            const rq_wc: u16 = 1 + @as(u16, @intCast(std.math.divCeil(usize, rq_ext.len + 1, 4) catch unreachable));
            try self.emitWord(spirv.encodeInstructionHeader(rq_wc, @intFromEnum(spirv.Op.Extension)));
            const rq_nw = std.math.divCeil(usize, rq_ext.len + 1, 4) catch unreachable;
            const rq_ew = try self.alloc.alloc(u32, rq_nw);
            @memset(rq_ew, 0);
            for (rq_ext, 0..) |byte, idx| {
                rq_ew[idx / 4] |= @as(u32, byte) << @intCast((idx % 4) * 8);
            }
            for (rq_ew) |w| try self.emitWord(w);
            self.alloc.free(rq_ew);
        }
        if (self.module.uses_ray_query_position_fetch) {
            const rpf_ext = "SPV_KHR_ray_tracing_position_fetch";
            const rpf_wc: u16 = 1 + @as(u16, @intCast(std.math.divCeil(usize, rpf_ext.len + 1, 4) catch unreachable));
            try self.emitWord(spirv.encodeInstructionHeader(rpf_wc, @intFromEnum(spirv.Op.Extension)));
            const rpf_nw = std.math.divCeil(usize, rpf_ext.len + 1, 4) catch unreachable;
            const rpf_ew = try self.alloc.alloc(u32, rpf_nw);
            @memset(rpf_ew, 0);
            for (rpf_ext, 0..) |byte, idx| {
                rpf_ew[idx / 4] |= @as(u32, byte) << @intCast((idx % 4) * 8);
            }
            for (rpf_ew) |w| try self.emitWord(w);
            self.alloc.free(rpf_ew);
        }
        // ARM tensor extension
        var needs_tensor_ext = self.module.uses_arm_tensors;
        if (!needs_tensor_ext) {
            for (self.module.globals) |global| {
                if (global.ty == .tensor_arm) { needs_tensor_ext = true; break; }
            }
        }
        if (needs_tensor_ext) {
            const arm_ext = "SPV_ARM_tensors";
            const arm_wc: u16 = 1 + @as(u16, @intCast(std.math.divCeil(usize, arm_ext.len + 1, 4) catch unreachable));
            try self.emitWord(spirv.encodeInstructionHeader(arm_wc, @intFromEnum(spirv.Op.Extension)));
            const arm_nw = std.math.divCeil(usize, arm_ext.len + 1, 4) catch unreachable;
            const arm_ew = try self.alloc.alloc(u32, arm_nw);
            @memset(arm_ew, 0);
            for (arm_ext, 0..) |byte, idx| {
                arm_ew[idx / 4] |= @as(u32, byte) << @intCast((idx % 4) * 8);
            }
            for (arm_ew) |w| try self.emitWord(w);
            self.alloc.free(arm_ew);
        }
        // Ray tracing extension
        if (self.stage == .raygen or self.stage == .closesthit or self.stage == .miss or
            self.stage == .intersection or self.stage == .anyhit or self.stage == .callable)
        {
            try self.emitExtensionString("SPV_KHR_ray_tracing");
        }
        // Mesh shading extension
        if (self.stage == .mesh or self.stage == .task) {
            try self.emitExtensionString("SPV_EXT_mesh_shader");
        }
        // Fragment shader interlock extension
        var has_interlock_ext = false;
        for (self.module.functions) |func| {
            for (func.body) |inst| {
                if (inst.tag == .begin_invocation_interlock or inst.tag == .end_invocation_interlock) {
                    has_interlock_ext = true;
                    break;
                }
            }
            if (has_interlock_ext) break;
        }
        if (has_interlock_ext) {
            try self.emitExtensionString("SPV_EXT_fragment_shader_interlock");
        }
        // GL_EXT/NV_fragment_shader_barycentric. The KHR and NV forms share the
        // same FragmentBarycentricKHR capability and BuiltIn/PerVertexKHR
        // decorations — only THIS extension string distinguishes them.
        {
            const bary = self.barycentricUsage();
            if (bary.used) {
                try self.emitExtensionString(if (bary.nv)
                    "SPV_NV_fragment_shader_barycentric"
                else
                    "SPV_KHR_fragment_shader_barycentric");
            }
        }
    }

    fn emitExtensionString(self: *Codegen, ext_name: []const u8) !void {
        const wc: u16 = 1 + @as(u16, @intCast(std.math.divCeil(usize, ext_name.len + 1, 4) catch unreachable));
        try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.Extension)));
        const nw = std.math.divCeil(usize, ext_name.len + 1, 4) catch unreachable;
        const ew = try self.alloc.alloc(u32, nw);
        @memset(ew, 0);
        for (ext_name, 0..) |byte, idx| {
            ew[idx / 4] |= @as(u32, byte) << @intCast((idx % 4) * 8);
        }
        for (ew) |w| try self.emitWord(w);
        self.alloc.free(ew);
    }

    fn emitExtInstImport(self: *Codegen) !void {
        // Only emit GLSL.std.450 import if the module actually uses ext_inst instructions
        var has_ext_inst = false;
        for (self.module.functions) |func| {
            for (func.body) |inst| {
                if (inst.tag == .ext_inst) {
                    has_ext_inst = true;
                    break;
                }
            }
            if (has_ext_inst) break;
        }
        if (!has_ext_inst) return;

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
            .tessellation_control => .TessellationControl,
            .tessellation_evaluation => .TessellationEvaluation,
            .mesh => .MeshEXT,
            .task => .TaskEXT,
            .raygen => .RayGenerationKHR,
            .closesthit => .ClosestHitKHR,
            .miss => .MissKHR,
            .intersection => .IntersectionKHR,
            .anyhit => .AnyHitKHR,
            .callable => .CallableKHR,
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
            if (global.result_id == 0) continue; // Skip unassigned globals
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

            if (self.module.early_fragment_tests) {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.EarlyFragmentTests));
            }
            if (self.module.pixel_interlock_ordered) {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.PixelInterlockOrderedEXT));
            }
            if (self.module.pixel_interlock_unordered) {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.PixelInterlockUnorderedEXT));
            }
            if (self.module.sample_interlock_ordered) {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.SampleInterlockOrderedEXT));
            }
            if (self.module.sample_interlock_unordered) {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.SampleInterlockUnorderedEXT));
            }
            // If gl_FragDepth is used, emit DepthReplacing
            var has_frag_depth = false;
            for (self.module.globals) |g| {
                if (std.mem.eql(u8, g.name, "gl_FragDepth")) {
                    has_frag_depth = true;
                    break;
                }
            }
            if (has_frag_depth) {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.DepthReplacing));
            }
            if (self.module.depth_greater) {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.DepthGreater));
            }
            if (self.module.depth_less) {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.DepthLess));
            }
            if (self.module.depth_unchanged) {
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.DepthUnchanged));
            }
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
        // Task shaders use LocalSize same as compute
        if (stage == .task) {
            if (self.module.local_size) |ls| {
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.LocalSize));
                try self.emitWord(ls.x);
                try self.emitWord(ls.y);
                try self.emitWord(ls.z);
            }
        }
        // Mesh shader execution modes
        if (stage == .mesh) {
            if (self.module.local_size) |ls| {
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.LocalSize));
                try self.emitWord(ls.x);
                try self.emitWord(ls.y);
                try self.emitWord(ls.z);
            }
            if (self.module.mesh_output_topology) |topo| {
                const topo_mode: spirv.ExecutionMode = switch (topo) {
                    .triangles => .OutputTrianglesEXT,
                    .lines => .OutputLinesEXT,
                    .points => .OutputPoints,
                };
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(topo_mode));
            }
            if (self.module.mesh_max_vertices) |mv| {
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.OutputVertices));
                try self.emitWord(mv);
            }
            if (self.module.mesh_max_primitives) |mp| {
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.OutputPrimitivesEXT));
                try self.emitWord(mp);
            }
        }
        // Ray tracing stages: no LocalSize needed (not supported for these execution models)

        // Geometry shader execution modes
        if (stage == .geometry) {
            if (self.module.geometry_input_topology) |topo| {
                const topo_mode: spirv.ExecutionMode = switch (topo) {
                    .points => .InputPoints,
                    .lines => .InputLines,
                    .lines_adjacency => .InputLinesAdjacency,
                    .triangles => .Triangles,
                    .triangles_adjacency => .InputTrianglesAdjacency,
                };
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(topo_mode));
            }
            if (self.module.geometry_output_topology) |topo| {
                const topo_mode: spirv.ExecutionMode = switch (topo) {
                    .triangles => .OutputTriangleStrip,
                    .lines => .OutputLineStrip,
                    .points => .OutputPoints,
                };
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(topo_mode));
            }
            if (self.module.geometry_max_vertices) |mv| {
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.OutputVertices));
                try self.emitWord(mv);
            }
        }
        // Tessellation execution modes
        if (stage == .tessellation_control) {
            if (self.module.tess_vertices) |v| {
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.OutputVertices));
                try self.emitWord(v);
            }
        }
        if (stage == .tessellation_evaluation) {
            if (self.module.tess_vertices) |v| {
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(spirv.ExecutionMode.OutputVertices));
                try self.emitWord(v);
            }
            // Spacing
            {
                const spacing = self.module.tess_spacing orelse .equal;
                const mode: spirv.ExecutionMode = switch (spacing) {
                    .equal => .SpacingEqual,
                    .fractional_even => .SpacingFractionalEven,
                    .fractional_odd => .SpacingFractionalOdd,
                };
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(mode));
            }
            // Vertex order
            {
                const ccw = self.module.tess_vertex_order_ccw orelse true;
                const mode: spirv.ExecutionMode = if (ccw) .VertexOrderCcw else .VertexOrderCw;
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(mode));
            }
            // Input topology
            {
                const topo = self.module.tess_input_topology orelse .triangles;
                const topo_mode: spirv.ExecutionMode = switch (topo) {
                    .triangles => .Triangles,
                    .lines => .Isolines,
                    else => .Triangles,
                };
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecutionMode)));
                try self.emitWord(entry_id);
                try self.emitWord(@intFromEnum(topo_mode));
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

    /// Map an `ast.ImageFormat` to its SPIR-V `Image Format` enum value.
    /// Mirrors the SPIR-V spec — `Unknown=0` is implicit when no qualifier was
    /// supplied (caller emits 0 in that case).
    fn imageFormatToSpv(f: ast.ImageFormat) u32 {
        return switch (f) {
            .rgba32f => 1, .rgba16f => 2, .r32f => 3, .rgba8 => 4, .rgba8_snorm => 5,
            .rg32f => 6, .rg16f => 7, .r11f_g11f_b10f => 8, .r16f => 9, .rgba16 => 10,
            .rgb10_a2 => 11, .rg16 => 12, .rg8 => 13, .r16 => 14, .r8 => 15,
            .rgba16_snorm => 16, .rg16_snorm => 17, .rg8_snorm => 18, .r16_snorm => 19, .r8_snorm => 20,
            .rgba32i => 21, .rgba16i => 22, .rgba8i => 23, .r32i => 24, .rg32i => 25,
            .rg16i => 26, .rg8i => 27, .r16i => 28, .r8i => 29,
            .rgba32ui => 30, .rgba16ui => 31, .rgba8ui => 32, .r32ui => 33, .rgb10_a2ui => 34,
            .rg32ui => 35, .rg16ui => 36, .rg8ui => 37, .r16ui => 38, .r8ui => 39,
        };
    }

    /// Emit an `OpTypeImage` for a storage image (`Sampled=2`) with the
    /// `Format` operand populated from the GLSL `layout(rgbaN)` qualifier.
    /// Returns the freshly allocated result id. Caller is responsible for
    /// pinning this id in `emitted_types` so subsequent type lookups reuse it.
    fn emitStorageImageType(self: *Codegen, ty: ast.Type, fmt: ast.ImageFormat) error{OutOfMemory}!u32 {
        // (dim, depth, arrayed, multisampled) per SPIR-V `Image Dim`/operands.
        const ImageShape = struct { dim: u32, arrayed: u32, multisampled: u32 };
        const shape: ImageShape = switch (ty) {
            .image2d, .iimage2d, .uimage2d => .{ .dim = 1, .arrayed = 0, .multisampled = 0 },
            .image2d_ms => .{ .dim = 1, .arrayed = 0, .multisampled = 1 },
            .image2d_ms_array => .{ .dim = 1, .arrayed = 1, .multisampled = 1 },
            .image2d_array, .iimage2d_array, .uimage2d_array => .{ .dim = 1, .arrayed = 1, .multisampled = 0 },
            .image3d, .iimage3d, .uimage3d => .{ .dim = 2, .arrayed = 0, .multisampled = 0 },
            .image_cube, .iimage_cube, .uimage_cube => .{ .dim = 3, .arrayed = 0, .multisampled = 0 },
            .image_cube_array, .iimage_cube_array, .uimage_cube_array => .{ .dim = 3, .arrayed = 1, .multisampled = 0 },
            .image1d, .iimage1d, .uimage1d => .{ .dim = 0, .arrayed = 0, .multisampled = 0 },
            .image_buffer, .iimage_buffer, .uimage_buffer => .{ .dim = 5, .arrayed = 0, .multisampled = 0 },
            else => unreachable, // caller must filter to storage images
        };
        const base: ast.Type = ty.samplerBaseType();
        const base_id = try self.ensureType(base);
        const id = self.allocId();
        try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
        try self.emitTypeWord(id);
        try self.emitTypeWord(base_id);
        try self.emitTypeWord(shape.dim);
        try self.emitTypeWord(0); // Depth
        try self.emitTypeWord(shape.arrayed);
        try self.emitTypeWord(shape.multisampled);
        try self.emitTypeWord(2); // Sampled = 2 (storage image)
        try self.emitTypeWord(imageFormatToSpv(fmt));
        return id;
    }

    /// Format-aware dedup key for a storage-image type (#183). Distinct
    /// `(enum, format)` pairs map to distinct OpTypeImage ids so that two
    /// `image2D`s with different `layout(rgbaN)` qualifiers don't collapse.
    fn storageImageKey(ty: ast.Type, fmt: ast.ImageFormat) u64 {
        return (@as(u64, @intFromEnum(ty)) << 8) | @as(u64, @intFromEnum(fmt));
    }

    /// Get (or emit + cache) a format-aware storage-image `OpTypeImage` id.
    /// Routes through `emitted_storage_image_types`, NEVER the format-blind
    /// `emitted_types`, so per-image formats are preserved (#183).
    fn ensureStorageImageType(self: *Codegen, ty: ast.Type, fmt: ast.ImageFormat) error{OutOfMemory}!u32 {
        const key = storageImageKey(ty, fmt);
        if (self.emitted_storage_image_types.get(key)) |cached| return cached;
        const id = try self.emitStorageImageType(ty, fmt);
        try self.emitted_storage_image_types.put(self.alloc, key, id);
        return id;
    }

    /// Resolve the base TYPE id for a storage-image global with format `fmt`
    /// (#183). For a scalar `image2D` this is the format-aware OpTypeImage; for
    /// an array `image2D arr[N]` it is an OpTypeArray whose element is that
    /// format-aware image. Recurses through nested arrays. The array element id
    /// is threaded explicitly so the format-blind `ensureType(.array)` →
    /// `ensureType(.image2d)` path (which emits Unknown) is bypassed.
    fn ensureStorageImageBaseType(self: *Codegen, ty: ast.Type, fmt: ast.ImageFormat) error{OutOfMemory}!u32 {
        switch (ty) {
            .array => |arr| {
                const elem_id = try self.ensureStorageImageBaseType(arr.base.*, fmt);
                // Key the array on the format-aware element id so two arrays of
                // distinct-format images stay distinct.
                const cache_key = arrayCacheKey(elem_id, arr.size, self.array_layout_ctx);
                if (self.emitted_array_types.get(cache_key)) |cached| return cached;
                const id = self.allocId();
                if (arr.size == 0) {
                    try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeRuntimeArray)));
                    try self.emitTypeWord(id);
                    try self.emitTypeWord(elem_id);
                } else {
                    const const_id = try self.emitIntConstant(arr.size);
                    try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeArray)));
                    try self.emitTypeWord(id);
                    try self.emitTypeWord(elem_id);
                    try self.emitTypeWord(const_id);
                }
                try self.emitted_array_types.put(self.alloc, cache_key, id);
                return id;
            },
            else => return try self.ensureStorageImageType(ty, fmt),
        }
    }

    /// Resolve the declared storage-image format for a pointer id (#183),
    /// following `constant_alias` (e.g. a reloaded pointer). Returns the format
    /// recorded for the originating global, or null if the ptr is not a tracked
    /// storage image. Used to thread per-image formats into access chains and
    /// loads so they match the OpVariable's format-aware pointee type.
    fn storageImageFormatForPtr(self: *Codegen, ptr_id: u32) ?ast.ImageFormat {
        if (self.storage_image_format_by_ptr.get(ptr_id)) |fmt| return fmt;
        if (self.constant_alias.get(ptr_id)) |aliased| {
            if (aliased != ptr_id) return self.storage_image_format_by_ptr.get(aliased);
        }
        return null;
    }

    /// Emit a pointer type whose pointee is the format-aware storage-image
    /// (or array-of-image) type for a global declared `layout(rgbaN)` (#183).
    fn ensureStorageImagePointerType(self: *Codegen, ty: ast.Type, fmt: ast.ImageFormat, storage_class: ir.SPIRVStorageClass) error{OutOfMemory}!u32 {
        const base_id = try self.ensureStorageImageBaseType(ty, fmt);
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

    fn ensureType(self: *Codegen, ty: ast.Type) error{OutOfMemory}!u32 {
        // Normalize aliases for dedup: mat2 == mat2x2, mat3 == mat3x3, mat4 == mat4x4
        const normalized = switch (ty) {
            .mat2 => ast.Type.mat2x2,
            .mat3 => ast.Type.mat3x3,
            .mat4 => ast.Type.mat4x4,
            else => ty,
        };
        // Dedup: for simple (non-payload) types, return cached ID if already emitted
        if (normalized != .named and normalized != .array and normalized != .tensor_arm) {
            const key = @intFromEnum(normalized);
            if (self.emitted_types.get(key)) |cached_id| {
                return cached_id;
            }
        }
        // Dedup tensor types by (element_type, rank)
        if (ty == .tensor_arm) {
            const ta = ty.tensor_arm;
            // We need the element type ID, but ensureType isn't available here recursively
            // Instead, hash based on AST type enum + rank
            const elem_key = @intFromEnum(ta.element.*);
            const tensor_key = (@as(u64, elem_key) << 32) | @as(u64, ta.rank);
            if (self.emitted_tensor_types.get(tensor_key)) |cached_id| {
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler1d_array => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(0); // Dim = 1D
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1 (yes)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
            .iimage_buffer => {
                const int_id = try self.ensureType(.int);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(int_id);
                try self.emitTypeWord(5); // Dim = Buffer
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(2); // Sampled = 2
                try self.emitTypeWord(0); // ImageFormat = Unknown
            },
            .uimage_buffer => {
                const uint_id = try self.ensureType(.uint);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(uint_id);
                try self.emitTypeWord(5); // Dim = Buffer
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(2); // Sampled = 2
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .sampler_cube_array => {
                const float_id = try self.ensureType(.float);
                const image_id = self.allocId();
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(image_id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(3); // Dim = Cube
                try self.emitTypeWord(0); // Depth = 0
                try self.emitTypeWord(1); // Arrayed = 1
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(1); // Sampled = 1 (with sampler)
                try self.emitTypeWord(0); // ImageFormat = Unknown
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
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
                try self.sampled_image_inner_by_type.put(self.alloc, std.meta.activeTag(ty), image_id); // inner image for OpImage extraction (#188)
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeSampledImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(image_id);
            },
            .named => |name| {
                // Check if this named type was already emitted
                // In interface block context, prefer interface version (bool->uint)
                if (self.in_interface_block) {
                    if (self.emitted_interface_named_types.get(name)) |cached_id| {
                        return cached_id;
                    }
                }
                if (self.emitted_named_types.get(name)) |cached_id| {
                    if (!self.in_interface_block) return cached_id;
                    // In interface context but only normal version cached — fall through to create interface version
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
                if (self.in_interface_block) {
                    try self.emitted_interface_named_types.put(self.alloc, name, id);
                } else {
                    try self.emitted_named_types.put(self.alloc, name, id);
                }

                // Pre-check: is this struct (or its parent) used as Block (UBO/SSBO)?
                // If so, set in_interface_block for bool->uint member conversion
                const prev_interface = self.in_interface_block;
                var is_block_struct = false;
                if (!self.in_interface_block) {
                    for (self.module.globals) |global| {
                        if (global.storage_class != .uniform and global.storage_class != .storage_buffer) continue;
                        if (global.ty != .named) continue;
                        if (std.mem.eql(u8, global.ty.named, name)) {
                            is_block_struct = true;
                            break;
                        }
                    }
                    // Also check if this type is a member of a Block-decorated struct (transitive)
                    if (!is_block_struct) blk: {
                        for (self.module.globals) |global| {
                            if (global.storage_class != .uniform and global.storage_class != .storage_buffer) continue;
                            if (global.ty != .named) continue;
                            const gtd = self.module.types.get(global.ty.named) orelse continue;
                            for (gtd.members) |gmember| {
                                var resolved = gmember.ty;
                                while (resolved == .array) resolved = resolved.array.base.*;
                                if (resolved == .named and std.mem.eql(u8, resolved.named, name)) {
                                    is_block_struct = true;
                                    break :blk;
                                }
                            }
                        }
                    }
                    if (is_block_struct) self.in_interface_block = true;
                }

                var self_ptr_id: u32 = 0;
                if (td.is_buffer_reference) {
                    // Check for direct self-reference first
                    var has_self_ref = false;
                    for (td.members) |member| {
                        var resolved_ty = member.ty;
                        while (resolved_ty == .array) resolved_ty = resolved_ty.array.base.*;
                        if (resolved_ty == .named and std.mem.eql(u8, resolved_ty.named, name)) {
                            has_self_ref = true;
                            break;
                        }
                    }
                    // Check for indirect self-reference: any member whose struct type
                    // transitively contains a buffer_reference to this type
                    if (!has_self_ref) {
                        for (td.members) |member| {
                            var resolved_ty = member.ty;
                            while (resolved_ty == .array) resolved_ty = resolved_ty.array.base.*;
                            if (resolved_ty == .named) {
                                const nested_td = self.module.types.get(resolved_ty.named);
                                if (nested_td) |ntd| {
                                    for (ntd.members) |nested_member| {
                                        var nr = nested_member.ty;
                                        while (nr == .array) nr = nr.array.base.*;
                                        if (nr == .named and std.mem.eql(u8, nr.named, name)) {
                                            has_self_ref = true;
                                            break;
                                        }
                                    }
                                }
                            }
                            if (has_self_ref) break;
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

                // Resolve the block layout BEFORE the member loop so array members
                // can be created with the right ArrayStride context, and BEFORE the
                // dedup key so the key can fold it in. This loop only READS
                // self.module.globals to set the locals needs_block / block_layout /
                // block_row_major (it mutates no self.* state); the actual decoration
                // emission stays below, after the struct / OpName / OpMemberName.
                var needs_block = false;
                // Layout resolution:
                //   explicit layout(std430)         -> .std430
                //   explicit layout(std140)         -> .std140
                //   no explicit qualifier           -> self.default_layout (.std140 by default,
                //                                      or .scalar if GL_EXT_scalar_block_layout is enabled)
                var block_layout: LayoutKind = self.default_layout;
                var block_row_major = false;
                for (self.module.globals) |global| {
                    if (global.storage_class != .uniform and global.storage_class != .storage_buffer) continue;
                    if (global.ty != .named) continue;
                    if (!std.mem.eql(u8, global.ty.named, name)) continue;
                    needs_block = true;
                    if (global.layout) |l| {
                        if (l.std430) block_layout = .std430
                        else if (l.std140) block_layout = .std140;
                        block_row_major = l.row_major;
                    }
                    break;
                }
                // Buffer_reference types also need Block decoration
                if (td.is_buffer_reference) needs_block = true;

                // Make the resolved layout the active array-stride context for the
                // member loop AND the emitNestedStructLayout call below (the defer
                // restores it on every exit path, including the dedup cache-hit
                // early return). Only a DIRECT std140/std430 block sets the context;
                // everything else — plain structs, buffer_reference blocks, and
                // NESTED structs reached recursively from a block's member loop —
                // resets it to null. That deliberately keeps arrays INSIDE a shared
                // named nested struct unsplit: splitting them would fork the struct
                // itself into per-layout variants, which the 1:1 struct-name → id
                // access-chain resolution cannot follow (a separate follow-up). Only
                // arrays that are DIRECT block members (the std140-vs-std430 stride
                // collision this fix targets) get distinct per-layout array types.
                const prev_array_ctx = self.array_layout_ctx;
                defer self.array_layout_ctx = prev_array_ctx;
                self.array_layout_ctx = if (needs_block and !td.is_buffer_reference) block_layout else null;

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
                    // In interface block context, replace bool with uint for struct members
                    // SPIR-V requires Block structs to use uint instead of bool
                    var member_ty = member.ty;
                    if (self.in_interface_block and member_ty == .bool) {
                        member_ty = .uint;
                    }
                    // Also convert bvecN to uvecN for interface blocks
                    if (self.in_interface_block) {
                        member_ty = switch (member_ty) {
                            .bvec2 => .uvec2,
                            .bvec3 => .uvec3,
                            .bvec4 => .uvec4,
                            else => member_ty,
                        };
                    }
                    try member_ids.append(self.alloc, try self.ensureType(member_ty));
                }
                // needs_block / block_layout / block_row_major were resolved above,
                // before the member loop, so the array members got the right stride
                // context.

                // Check if a struct with the same member layout was already emitted.
                // The key folds in member NAMES as well as member types (two blocks
                // with byte-identical layouts but different member names, e.g.
                // `A { vec4 ca }` vs `B { vec4 cb }`, are distinct types and must NOT
                // be merged — reusing one id would alias the other block's member
                // names and decorations onto it, so `b.cb` would resolve to `ca`) AND
                // the resolved block layout. The block_row_major bit is what keeps a
                // `row_major` block distinct from a `column_major` one with identical
                // members: their matrix members carry different RowMajor/ColMajor +
                // MatrixStride OpMemberDecorate, so the structs must not share an id.
                // block_layout (std140/std430/scalar) is folded too for completeness —
                // it separates structs whose member-level Offset decorations differ by
                // layout. Two blocks differing ONLY in std140-vs-std430 ARRAY stride
                // are now separated as well: array types fold the block layout into
                // their identity (see array_layout_ctx / arrayCacheKey), so the blocks
                // reference different array type ids → different member_ids → different
                // key. (Still open, separate follow-up: a NAMED nested struct shared by
                // an std140 and an std430 block keeps a single shared type — its arrays
                // are deliberately left unsplit so the struct stays resolvable, so one
                // of the two layouts gets silently-wrong member offsets.)
                var layout_key: u64 = @as(u64, member_ids.items.len);
                for (member_ids.items) |mid| {
                    layout_key = layout_key *% 33 +% @as(u64, mid);
                }
                for (td.members) |member| {
                    for (member.name) |c| layout_key = layout_key *% 33 +% @as(u64, c);
                    layout_key = layout_key *% 33 +% 0xFF; // member-name boundary
                }
                layout_key = layout_key *% 33 +% @as(u64, @intFromEnum(block_layout));
                layout_key = layout_key *% 33 +% @as(u64, @intFromBool(block_row_major));
                // Fold needs_block too: a plain struct and a uniform/storage BLOCK
                // with byte-identical members + names + default layout otherwise
                // share a key and merge, but only the block carries Block + Offset
                // decorations. Merging would leave the uniform variable pointing at
                // a non-Block struct (invalid for Vulkan) or stamp Block/Offset onto
                // a plain struct. This only ADDS discrimination — truly-identical
                // types share needs_block so still merge.
                layout_key = layout_key *% 33 +% @as(u64, @intFromBool(needs_block));
                if (self.emitted_struct_layouts.get(layout_key)) |cached_id| {
                    // Reuse existing struct type — update name mapping too
                    if (self.in_interface_block) {
                        try self.emitted_interface_named_types.put(self.alloc, name, cached_id);
                    } else {
                        try self.emitted_named_types.put(self.alloc, name, cached_id);
                    }
                    return cached_id;
                }

                const word_count: u16 = 2 + @as(u16, @intCast(member_ids.items.len));
                try self.emitTypeWord(spirv.encodeInstructionHeader(word_count, @intFromEnum(spirv.Op.TypeStruct)));
                try self.emitTypeWord(id);
                for (member_ids.items) |mid| {
                    try self.emitTypeWord(mid);
                }
                try self.emitted_struct_layouts.put(self.alloc, layout_key, id);
                // Emit OpName for this struct type
                try self.emitNameSectionName(id, name);
                // Emit OpMemberName for each struct member
                for (td.members, 0..) |member, i| {
                    if (member.name.len > 0) {
                        try self.emitNameSectionMemberName(id, @as(u32, @intCast(i)), member.name);
                    }
                }
                // Emit UBO/SSBO decorations: Block + Offset/MatrixStride/ArrayStride.
                // needs_block / block_layout / block_row_major were resolved above
                // (before the dedup key) so the key could fold in the layout qualifiers.
                if (needs_block) {
                    try self.emitDecorationSectionDecorateNoExtra(id, @intFromEnum(spirv.Decoration.block));
                    self.default_row_major = block_row_major;
                    try self.emitNestedStructLayout(id, td.members, block_layout);
                    self.default_row_major = false;
                }
                // If we emitted a forward pointer, now emit the actual pointer definition
                if (self_ptr_id != 0) {
                    try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypePointer)));
                    try self.emitTypeWord(self_ptr_id);
                    try self.emitTypeWord(5349); // PhysicalStorageBuffer
                    try self.emitTypeWord(id); // The struct type
                }
                // Restore interface block context
                self.in_interface_block = prev_interface;
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

                // Fold the active block layout into the key so a `T[N]` member of
                // an std140 block and of an std430 block become DISTINCT array
                // types — each gets its own ArrayStride. Outside a Block the
                // context is null and this reduces to the original (base, size) key.
                const cache_key = arrayCacheKey(base_id, arr.size, self.array_layout_ctx);
                if (self.emitted_array_types.get(cache_key)) |cached_id| {
                    return cached_id;
                }
                if (arr.size_name) |sname| {
                    // Spec constant array size: use the spec constant result ID
                    if (self.module.spec_constants.get(sname)) |sc| {
                        try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeArray)));
                        try self.emitTypeWord(id);
                        try self.emitTypeWord(base_id);
                        try self.emitTypeWord(sc.result_id);
                    } else {
                        // Fallback: runtime array
                        try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.TypeRuntimeArray)));
                        try self.emitTypeWord(id);
                        try self.emitTypeWord(base_id);
                    }
                } else if (arr.size == 0) {
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
            // Separate sampler/texture types
            .sampler_plain => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.TypeSampler)));
                try self.emitTypeWord(id);
            },
            .texture2d_plain => {
                // Reuse the image type from sampler2d (same TypeImage params)
                // Ensure sampler2d is emitted first to set sampled_image_inner_id
                _ = try self.ensureType(.sampler2d);
                // The image type was already emitted as part of sampler2d
                // We need to get the same type ID that sampler2d used
                if (self.emitted_types.get(@intFromEnum(ast.Type.texture2d_plain))) |cached| {
                    return cached;
                }
                // Store the same image ID as what sampler2d used
                try self.emitted_types.put(self.alloc, @intFromEnum(ast.Type.texture2d_plain), self.sampled_image_inner_id);
                return self.sampled_image_inner_id;
            },
            .texture3d_plain => {
                _ = try self.ensureType(.sampler3d);
                if (self.emitted_types.get(@intFromEnum(ast.Type.texture3d_plain))) |cached| return cached;
                try self.emitted_types.put(self.alloc, @intFromEnum(ast.Type.texture3d_plain), self.sampled_image_3d_inner_id);
                return self.sampled_image_3d_inner_id;
            },
            .texture_cube_plain => {
                _ = try self.ensureType(.sampler_cube);
                if (self.emitted_types.get(@intFromEnum(ast.Type.texture_cube_plain))) |cached| return cached;
                // sampler_cube's ensureType arm recorded its inner image id in
                // the map; reuse it for the separate textureCube type (#188).
                const cube_inner = self.sampled_image_inner_by_type.get(.sampler_cube) orelse 0;
                try self.emitted_types.put(self.alloc, @intFromEnum(ast.Type.texture_cube_plain), cube_inner);
                return cube_inner;
            },
            .texture2d_array_plain => {
                _ = try self.ensureType(.sampler2d_array);
                if (self.emitted_types.get(@intFromEnum(ast.Type.texture2d_array_plain))) |cached| return cached;
                try self.emitted_types.put(self.alloc, @intFromEnum(ast.Type.texture2d_array_plain), self.sampled_image_2d_array_inner_id);
                return self.sampled_image_2d_array_inner_id;
            },
            .texture2d_ms_plain => {
                _ = try self.ensureType(.sampler2d_ms);
                if (self.emitted_types.get(@intFromEnum(ast.Type.texture2d_ms_plain))) |cached| return cached;
                try self.emitted_types.put(self.alloc, @intFromEnum(ast.Type.texture2d_ms_plain), self.sampled_image_ms_inner_id);
                return self.sampled_image_ms_inner_id;
            },
            .subpass_input => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(6); // Dim = SubpassData
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(0); // Not multisampled
                try self.emitTypeWord(2); // Sampled = 2 (no sampler needed)
                try self.emitTypeWord(0); // ImageFormat = Unknown
            },
            .subpass_input_ms => {
                const float_id = try self.ensureType(.float);
                try self.emitTypeWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.TypeImage)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(float_id);
                try self.emitTypeWord(6); // Dim = SubpassData
                try self.emitTypeWord(0); // Not depth
                try self.emitTypeWord(0); // Not arrayed
                try self.emitTypeWord(1); // Multisampled = 1
                try self.emitTypeWord(2); // Sampled = 2 (no sampler needed)
                try self.emitTypeWord(0); // ImageFormat = Unknown
            },
            .acceleration_structure_ext => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.TypeAccelerationStructureKHR)));
                try self.emitTypeWord(id);
            },
            .ray_query_ext => {
                try self.emitTypeWord(spirv.encodeInstructionHeader(2, @intFromEnum(spirv.Op.TypeRayQueryKHR)));
                try self.emitTypeWord(id);
            },
            .tensor_arm => |ta| {
                const elem_type_id = try self.ensureType(ta.element.*);
                const rank_id = try self.emitIntConstant(ta.rank);
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypeTensorARM)));
                try self.emitTypeWord(id);
                try self.emitTypeWord(elem_type_id);
                try self.emitTypeWord(rank_id);
                // Cache for dedup
                const elem_key = @intFromEnum(ta.element.*);
                const tensor_key = (@as(u64, elem_key) << 32) | @as(u64, ta.rank);
                try self.emitted_tensor_types.put(self.alloc, tensor_key, id);
            },
        }
        // Cache for simple types
        if (normalized != .named and normalized != .array and normalized != .tensor_arm) {
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
        // Emit OpName for specialization constants so cross-compiled output
        // surfaces the user-declared identifier (e.g., `SIZE`) instead of
        // the backend's auto-generated `v{id}` fallback. The `spec_constants`
        // map is keyed by the original GLSL identifier; for derived
        // `spec_constant_ops`, only entries that received a user-facing
        // binding (top-level `const T NAME = <spec-expr>;`) carry a
        // `user_name` -- intermediate sub-expressions stay anonymous.
        {
            var sc_iter = self.module.spec_constants.iterator();
            while (sc_iter.next()) |entry| {
                try self.emitName(entry.value_ptr.result_id, entry.key_ptr.*);
            }
        }
        {
            var sco_iter = self.module.spec_constant_ops.iterator();
            while (sco_iter.next()) |entry| {
                if (entry.value_ptr.user_name) |name| {
                    try self.emitName(entry.value_ptr.result_id, name);
                }
            }
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
                } else if (layout.binding != null and (global.storage_class == .uniform or global.storage_class == .storage_buffer or global.storage_class == .uniform_constant)) {
                    // Default descriptor set is 0 for UBO/SSBO
                    try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.descriptor_set), 0);
                }
                if (layout.input_attachment_index != null) {
                    try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.input_attachment_index), layout.input_attachment_index.?);
                }
            }
            if (std.mem.eql(u8, global.name, "gl_FragCoord")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.frag_coord));
            }
            if (std.mem.eql(u8, global.name, "gl_FragDepth")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.frag_depth));
            }
            if (std.mem.eql(u8, global.name, "gl_FragColor")) {
                // gl_FragColor is deprecated, no standard BuiltIn — skip decoration
            } else if (std.mem.eql(u8, global.name, "gl_FrontFacing")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.front_facing));
            } else if (std.mem.eql(u8, global.name, "gl_HelperInvocation")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.helper_invocation));
            }
            if (std.mem.eql(u8, global.name, "gl_PointCoord")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.point_coord));
            }
            // Geometry shader gl_in array (array of vec4 with Position)
            if (std.mem.eql(u8, global.name, "gl_in")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.position));
            }
            // TCS gl_out array (array of vec4 with Position)
            if (std.mem.eql(u8, global.name, "gl_out")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.position));
            }
            if (std.mem.eql(u8, global.name, "gl_Position")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.position));
            }
            if (std.mem.eql(u8, global.name, "gl_PointSize")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.point_size));
            }
            if (std.mem.eql(u8, global.name, "gl_ClipDistance")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.clip_distance));
            }
            if (std.mem.eql(u8, global.name, "gl_CullDistance")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.cull_distance));
            }
            // Geometry/Tessellation builtins
            if (std.mem.eql(u8, global.name, "gl_PrimitiveIDIn")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.primitive_id));
            }
            if (std.mem.eql(u8, global.name, "gl_PrimitiveID")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.primitive_id));
            }
            if (std.mem.eql(u8, global.name, "gl_InvocationID")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.invocation_id));
            }
            if (std.mem.eql(u8, global.name, "gl_TessCoord")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.tess_coord));
            }
            if (std.mem.eql(u8, global.name, "gl_PatchVerticesIn")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.patch_vertices));
            }
            if (std.mem.eql(u8, global.name, "gl_TessLevelOuter")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.tess_level_outer));
            }
            if (std.mem.eql(u8, global.name, "gl_TessLevelInner")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.tess_level_inner));
            }
            if (std.mem.eql(u8, global.name, "gl_VertexID") or std.mem.eql(u8, global.name, "gl_VertexIndex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), 42); // VertexIndex
            }
            if (std.mem.eql(u8, global.name, "gl_InstanceID") or std.mem.eql(u8, global.name, "gl_InstanceIndex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), 43); // InstanceIndex
            }
            // gl_Layer, gl_ViewportIndex — layer/viewport output (geometry) or input (fragment)
            if (std.mem.eql(u8, global.name, "gl_Layer")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.layer));
            }
            if (std.mem.eql(u8, global.name, "gl_ViewportIndex")) {
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
            if (std.mem.eql(u8, global.name, "gl_BaseVertex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.base_vertex));
            }
            if (std.mem.eql(u8, global.name, "gl_BaseInstance")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.base_instance));
            }
            if (std.mem.eql(u8, global.name, "gl_DrawID")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.draw_index));
            }
            if (std.mem.eql(u8, global.name, "gl_DeviceIndex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.device_index));
            }
            if (std.mem.eql(u8, global.name, "gl_ViewIndex")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.view_index));
            }
            // KHR_ray_tracing builtin decorations
            if (std.mem.eql(u8, global.name, "gl_LaunchIDEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.launch_id_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_LaunchSizeEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.launch_size_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_WorldRayOriginEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.world_ray_origin_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_WorldRayDirectionEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.world_ray_direction_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_ObjectRayOriginEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.object_ray_origin_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_ObjectRayDirectionEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.object_ray_direction_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_RayTminEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.ray_tmin_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_RayTmaxEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.ray_tmax_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_InstanceCustomIndexEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.instance_custom_index_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_HitKindEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.hit_kind_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_IncomingRayFlagsEXT")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.incoming_ray_flags_khr));
            }
            // Sample-related builtins
            if (std.mem.eql(u8, global.name, "gl_SampleID")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.sample_id));
            }
            if (std.mem.eql(u8, global.name, "gl_SamplePosition")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.sample_position));
            }
            if (std.mem.eql(u8, global.name, "gl_SampleMaskIn")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.sample_mask));
            }
            if (std.mem.eql(u8, global.name, "gl_SampleMask")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.sample_mask));
            }
            // GL_EXT/NV_fragment_shader_barycentric input builtins. glslang
            // canonicalizes BOTH the EXT and NV spellings to the KHR BuiltIn
            // values (BaryCoordKHR=5286 / BaryCoordNoPerspKHR=5287). Without
            // these decorations the variables read garbage instead of the
            // interpolated barycentric coordinates (silent-wrong).
            if (std.mem.eql(u8, global.name, "gl_BaryCoordEXT") or std.mem.eql(u8, global.name, "gl_BaryCoordNV")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.bary_coord_khr));
            }
            if (std.mem.eql(u8, global.name, "gl_BaryCoordNoPerspEXT") or std.mem.eql(u8, global.name, "gl_BaryCoordNoPerspNV")) {
                try self.emitDecorate(global.result_id, @intFromEnum(spirv.Decoration.built_in), @intFromEnum(spirv.BuiltIn.bary_coord_no_persp_khr));
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
            // Emit Invariant decoration for invariant-qualified output variables
            if (global.qualifier.is_invariant and global.storage_class == .output) {
                try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.invariant));
            }
            // Emit Centroid decoration for centroid-qualified IO variables
            if (global.qualifier.is_centroid and (global.storage_class == .input or global.storage_class == .output)) {
                try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.centroid));
            }
            // Emit NoPerspective decoration for noperspective-qualified IO variables
            if (global.qualifier.is_noperspective and (global.storage_class == .input or global.storage_class == .output)) {
                try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.no_perspective));
            }
            // Emit PerPrimitiveEXT decoration for perprimitiveEXT-qualified
            // mesh-shader output variables. (M5.2 v2.b — required so the HLSL
            // backend can distinguish per-vertex vs per-primitive outputs.)
            if (global.qualifier.is_perprimitive_ext and global.storage_class == .output) {
                try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.per_primitive_ext));
            }
            // Emit PerVertexKHR decoration for pervertexEXT/pervertexNV-qualified
            // fragment inputs (per-vertex arrays AND per-vertex interface
            // blocks). Both spellings emit the IDENTICAL PerVertexKHR (5285)
            // decoration. We deliberately reference `per_vertex_nv` (=5285):
            // the `per_vertex_khr` enum tag holds a WRONG value (4285) that
            // exists only to dodge Zig's duplicate-enum-tag error — 5285 is the
            // real SPIR-V spec value for PerVertexKHR.
            if ((global.qualifier.is_pervertex_ext or global.qualifier.is_pervertex_nv) and global.storage_class == .input) {
                try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.per_vertex_nv));
            }
            // Emit NonWritable/NonReadable for readonly/writeonly storage buffers
            // and storage images. glslang emits NonWritable on a `readonly imageN`
            // and NonReadable on a `writeonly imageN`, which the WGSL backend reads
            // to pick the storage-texture access mode (read/write) instead of the
            // less-portable read_write default. The image case is gated on
            // isStorageImage() — NOT the whole uniform_constant class — because
            // spirv-val rejects these decorations on a sampled image / combined
            // sampler, and glslpp (unlike glslang) does not reject a bogus
            // `readonly sampler2D`; decorating it would emit invalid SPIR-V.
            if (global.storage_class == .storage_buffer or
                (global.storage_class == .uniform_constant and global.ty.isStorageImage()))
            {
                if (global.qualifier.is_readonly) {
                    try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.non_writable));
                }
                if (global.qualifier.is_writeonly) {
                    try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.non_readable));
                }
            }
            // Coherent and Restrict apply to storage buffers and uniform (image/sampler) variables
            if (global.storage_class == .storage_buffer or global.storage_class == .uniform_constant) {
                if (global.qualifier.is_coherent) {
                    try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.coherent));
                }
                if (global.qualifier.is_restrict) {
                    try self.emitDecorateNoExtra(global.result_id, @intFromEnum(spirv.Decoration.restrict));
                }
            }
        }
        // Emit SpecId decorations for SCALAR specialization constants.
        // For composite (vec/mat) spec consts the SpecId decorations go on each
        // per-scalar `OpSpecConstant` rather than on the
        // `OpSpecConstantComposite` (which has no literal payload to
        // override). Because component IDs aren't allocated until
        // `emitTypesAndConstants` runs, the composite-component decorations
        // are emitted there (into `decoration_section`, which is later
        // spliced into the annotation section).
        var spec_iter = self.module.spec_constants.iterator();
        while (spec_iter.next()) |entry| {
            const sc = entry.value_ptr.*;
            const TypeTagInner = @typeInfo(ast.Type).@"union".tag_type.?;
            const tag_inner: TypeTagInner = @enumFromInt(sc.type_tag);
            const is_composite = switch (tag_inner) {
                .vec2, .vec3, .vec4,
                .ivec2, .ivec3, .ivec4,
                .uvec2, .uvec3, .uvec4,
                .bvec2, .bvec3, .bvec4,
                .mat2, .mat3, .mat4,
                .mat2x2, .mat2x3, .mat2x4,
                .mat3x2, .mat3x3, .mat3x4,
                .mat4x2, .mat4x3, .mat4x4 => true,
                else => false,
            };
            if (is_composite) continue; // emitted later via decoration_section
            try self.emitDecorate(sc.result_id, @intFromEnum(spirv.Decoration.spec_id), sc.spec_id);
        }
        // QCOM image processing decorations
        if (self.module.uses_qcom_image_processing) {
            // Determine which QCOM decoration to apply based on operations used
            var has_block_match = false;
            var has_weighted = false;
            for (self.module.functions) |func| {
                for (func.body) |inst| {
                    switch (inst.tag) {
                        .image_block_match_sad_qcom, .image_block_match_ssd_qcom => has_block_match = true,
                        .image_sample_weighted_qcom => has_weighted = true,
                        else => {},
                    }
                }
            }
            // Apply QCOM decorations to all texture/sampler globals in UniformConstant
            for (self.module.globals) |global| {
                if (global.storage_class != .uniform_constant) continue;
                const is_texture = self.isTextureType(global.ty);
                if (!is_texture) continue;
                if (has_block_match) {
                    try self.emitDecorateNoExtra(global.result_id, 4488); // BlockMatchTextureQCOM
                }
                if (has_weighted) {
                    // WeightTextureQCOM only for the weight texture (last texture arg)
                    try self.emitDecorateNoExtra(global.result_id, 4487); // WeightTextureQCOM
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

    /// Compute alignment for a type under the given layout rule.
    fn layoutAlignment(self: *Codegen, ty: ast.Type, kind: LayoutKind) u32 {
        switch (kind) {
            .scalar => return self.layoutAlignmentScalar(ty),
            .std430 => return self.layoutAlignmentStd430(ty),
            .std140 => return self.layoutAlignmentStd140(ty),
        }
    }

    /// Resolve a named struct's emitted SPIR-V type id for layout computations.
    /// Interface-block structs (UBO/SSBO) are cached in
    /// `emitted_interface_named_types`; plain structs in `emitted_named_types`.
    /// The interface map must win — a struct reached through a block lives there,
    /// and missing it makes the layout recursion return silent-wrong defaults
    /// (#181). Returns null when the type was never emitted (both maps miss);
    /// each caller supplies its own per-site default for that case.
    fn resolveLayoutTypeId(self: *Codegen, name: []const u8) ?u32 {
        return self.emitted_interface_named_types.get(name) orelse
            self.emitted_named_types.get(name);
    }

    fn layoutAlignmentScalar(self: *Codegen, ty: ast.Type) u32 {
        // Scalar layout: alignment of any type is the alignment of its scalar component.
        // No 16-byte rounding, no vec3-to-vec4 padding.
        return switch (ty) {
            .int8, .uint8,
            .i8vec2, .u8vec2, .i8vec3, .u8vec3, .i8vec4, .u8vec4 => 1,
            .int16, .uint16, .float16,
            .i16vec2, .u16vec2, .f16vec2,
            .i16vec3, .u16vec3, .f16vec3,
            .i16vec4, .u16vec4, .f16vec4 => 2,
            .float, .int, .uint, .bool,
            .vec2, .ivec2, .uvec2,
            .vec3, .ivec3, .uvec3,
            .vec4, .ivec4, .uvec4,
            .mat2, .mat2x2, .mat3, .mat3x3, .mat4, .mat4x4,
            .mat2x3, .mat2x4, .mat3x2, .mat3x4, .mat4x2, .mat4x3 => 4,
            .array => |arr| self.layoutAlignmentScalar(arr.base.*),
            .named => |name| blk: {
                const td = self.module.types.get(name) orelse break :blk 4;
                if (td.is_buffer_reference) break :blk 8; // pointer alignment
                // A struct reached through a UBO/SSBO block is cached in
                // emitted_interface_named_types, not emitted_named_types (see
                // ensureType's in_interface_block split). Look there first so the
                // member alignment/size recursion finds the real members instead
                // of the silent-wrong default. (#181)
                const type_id = self.resolveLayoutTypeId(name) orelse break :blk 4;
                if (self.layout_visited.contains(type_id)) break :blk 8; // self-ref cycle: pointer
                self.layout_visited.put(self.alloc, type_id, {}) catch break :blk 4;
                defer _ = self.layout_visited.remove(type_id);
                var max_align: u32 = 1;
                for (td.members) |member| {
                    const ma = self.layoutAlignmentScalar(member.ty);
                    if (ma > max_align) max_align = ma;
                }
                break :blk max_align;
            },
            else => 4,
        };
    }

    fn layoutAlignmentStd430(self: *Codegen, ty: ast.Type) u32 {
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
                // Matrix alignment = stride of its stored vector (column for col_major,
                // row for row_major). std430 2-component vectors align to 8, not 16.
                .mat2, .mat2x2, .mat3, .mat3x3, .mat4, .mat4x4,
                .mat2x3, .mat2x4, .mat3x2, .mat3x4, .mat4x2, .mat4x3 => blk: {
                    const span = if (self.default_row_major)
                        self.matrixColumnCount(ty)
                    else
                        self.matrixRowCount(ty);
                    break :blk self.matrixMemberStride(span, .std430);
                },
            .array => |arr| self.layoutAlignmentStd430(arr.base.*), // std430: array alignment = element alignment
            .named => |name| blk: {
                // Struct alignment = max alignment of its members
                const td = self.module.types.get(name) orelse break :blk 16;
                if (td.is_buffer_reference) break :blk 8; // pointer alignment
                // Interface-block structs live in emitted_interface_named_types;
                // try it first or the recursion misses and returns 16 (#181).
                const type_id = self.resolveLayoutTypeId(name) orelse break :blk 16;
                if (self.layout_visited.contains(type_id)) break :blk 8; // self-ref cycle: pointer
                self.layout_visited.put(self.alloc, type_id, {}) catch break :blk 16;
                defer _ = self.layout_visited.remove(type_id);
                var max_align: u32 = 4;
                for (td.members) |member| {
                    const ma = self.layoutAlignmentStd430(member.ty);
                    if (ma > max_align) max_align = ma;
                }
                break :blk max_align;
            },
            else => 4,
        };
    }

    fn layoutAlignmentStd140(self: *Codegen, ty: ast.Type) u32 {
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
                // Interface-block structs live in emitted_interface_named_types;
                // try it first or the recursion misses and returns 16 (#181).
                const type_id = self.resolveLayoutTypeId(name) orelse break :blk 16;
                if (self.layout_visited.contains(type_id)) break :blk 16; // self-ref cycle: pointer (std140 rounds to 16)
                self.layout_visited.put(self.alloc, type_id, {}) catch break :blk 16;
                defer _ = self.layout_visited.remove(type_id);
                var max_align: u32 = 4;
                for (td.members) |member| {
                    const ma = self.layoutAlignmentStd140(member.ty);
                    if (ma > max_align) max_align = ma;
                }
                // std140 rule: a struct's base alignment is the max member
                // alignment ROUNDED UP to a multiple of 16 (vec4 alignment). So a
                // member following a scalar-only / vec2-only nested struct lands
                // at a 16-aligned offset (glslang ground truth). std430 does NOT
                // do this (see layoutAlignmentStd430) — keep them distinct.
                break :blk std.mem.alignForward(u32, max_align, 16);
            },
            else => 4,
        };
    }

    /// Compute size for a type under the given layout rule.
    fn layoutSize(self: *Codegen, ty: ast.Type, kind: LayoutKind) u32 {
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
            // Matrix size = (stored vector count) * (matrix stride). For col_major
            // the stored vectors are columns (span = rows); for row_major they are
            // rows (span = cols). matrixMemberStride encodes the per-layout column
            // alignment, so size stays consistent with the MatrixStride decoration.
            .mat2, .mat2x2, .mat2x3, .mat2x4,
            .mat3, .mat3x2, .mat3x3, .mat3x4,
            .mat4, .mat4x2, .mat4x3, .mat4x4 => blk: {
                const cols = self.matrixColumnCount(ty);
                const rows = self.matrixRowCount(ty);
                const vec_count = if (self.default_row_major) rows else cols;
                const span = if (self.default_row_major) cols else rows;
                break :blk vec_count * self.matrixMemberStride(span, kind);
            },
            .array => |arr| blk: {
                const stride = self.layoutArrayStride(ty, kind);
                break :blk stride * arr.size;
            },
            .named => |name| blk: {
                // Buffer_reference types used as members are pointers (8 bytes)
                const td = self.module.types.get(name) orelse break :blk 0;
                if (td.is_buffer_reference) break :blk 8;
                // Get the type_id for cycle detection. Interface-block structs
                // are cached in emitted_interface_named_types; look there first or
                // the size recursion misses and returns 0 — the member after a
                // nested struct then never advances and overlaps it (#181).
                const type_id = self.resolveLayoutTypeId(name) orelse {
                        // Both maps missed: the struct's type was never emitted
                        // before its layout was computed. Returning 0 here is the
                        // silent-wrong default that #181 was about — make it loud
                        // so a future regression is a visible warning, not a
                        // mislaid member that overlaps the next one.
                        std.log.warn("codegen.layoutSize: struct '{s}' not in emitted type maps; size defaults to 0 (member following it will overlap)", .{name});
                        break :blk 0;
                    };
                if (self.layout_visited.contains(type_id)) break :blk 8; // Self-referential: treat as pointer (8 bytes)
                self.layout_visited.put(self.alloc, type_id, {}) catch break :blk 0;
                var sz: u32 = 0;
                for (td.members) |member| {
                    const alignment = self.layoutAlignment(member.ty, kind);
                    sz = std.mem.alignForward(u32, sz, alignment);
                    sz += self.layoutSize(member.ty, kind);
                }
                // Remove from the cycle set BEFORE computing this struct's own
                // alignment: layoutAlignment(.named) re-enters the same guard and
                // would otherwise see type_id still present and return the
                // self-ref pointer alignment (8/16) instead of the real
                // max-member alignment — over-rounding the struct size. (#181)
                _ = self.layout_visited.remove(type_id);
                const struct_align = self.layoutAlignment(.{ .named = name }, kind);
                break :blk std.mem.alignForward(u32, sz, struct_align);
            },
            else => 4,
        };
    }

    /// Compute array stride under the given layout rule.
    fn layoutArrayStride(self: *Codegen, ty: ast.Type, kind: LayoutKind) u32 {
        const arr = ty.array;
        // For buffer_reference element types, use pointer size (8 bytes)
        var resolved_base = arr.base.*;
        while (resolved_base == .array) resolved_base = resolved_base.array.base.*;
        if (resolved_base == .named) {
            const td = self.module.types.get(resolved_base.named);
            if (td != null and td.?.is_buffer_reference) {
                // PhysicalStorageBuffer pointer is 8 bytes, 8-byte aligned
                const stride = std.mem.alignForward(u32, 8, 8);
                if (kind == .std430 or kind == .scalar) return stride;
                return std.mem.alignForward(u32, stride, 16); // std140
            }
        }
        const elem_size = self.layoutSize(arr.base.*, kind);
        const elem_align = self.layoutAlignment(arr.base.*, kind);
        const rounded_elem = std.mem.alignForward(u32, elem_size, elem_align);
        if (kind == .std430 or kind == .scalar) {
            return rounded_elem; // std430 / scalar: no extra rounding to 16
        }
        return std.mem.alignForward(u32, rounded_elem, 16); // std140: round up to vec4
    }

    /// Emit Offset/ColMajor/MatrixStride/ArrayStride for struct members, recursing into nested structs
    fn emitNestedStructLayout(self: *Codegen, struct_type_id: u32, members: []const ast.StructMember, kind: LayoutKind) !void {
        try self.emitNestedStructLayoutInner(struct_type_id, members, kind, self.default_row_major);
    }

    fn emitNestedStructLayoutInner(self: *Codegen, struct_type_id: u32, members: []const ast.StructMember, kind: LayoutKind, parent_row_major: bool) !void {
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
            const alignment = self.layoutAlignment(member.ty, kind);
            offset = std.mem.alignForward(u32, offset, alignment);
            try self.emitDecorationSectionMemberDecorate(struct_type_id, @intCast(i), @intFromEnum(spirv.Decoration.offset), offset);
            const size = self.layoutSize(member.ty, kind);
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
                // MatrixStride: stride between columns (col_major) or rows (row_major).
                // span = length of the stored vector (rows for col_major, cols for row_major).
                const span = if (member_is_row_major)
                    self.matrixColumnCount(effective_ty)
                else
                    self.matrixRowCount(effective_ty);
                const mat_stride = self.matrixMemberStride(span, kind);
                try self.emitDecorationSectionMemberDecorate(struct_type_id, @intCast(i), @intFromEnum(spirv.Decoration.matrix_stride), mat_stride);
            }
            // ArrayStride for array members (all nesting levels)
            if (member.ty == .array) {
                try self.emitArrayStrideRecursive(member.ty, kind);
                // Recurse into nested struct arrays: emit Offset for the element struct members
                if (effective_ty == .named) {
                    const elem_td = self.module.types.get(effective_ty.named) orelse continue;
                    const elem_type_id = self.resolveLayoutTypeId(effective_ty.named) orelse continue;
                    // Inside a nested struct the array-split context is null (its
                    // arrays were created unsplit), so its array-stride lookups must
                    // use the same null key.
                    const saved_ctx = self.array_layout_ctx;
                    self.array_layout_ctx = null;
                    defer self.array_layout_ctx = saved_ctx;
                    try self.emitNestedStructLayoutInner(elem_type_id, elem_td.members, kind, member_is_row_major);
                }
            }
            // Recurse into direct nested struct members
            if (member.ty == .named) {
                const nested_td = self.module.types.get(member.ty.named) orelse continue;
                const nested_type_id = self.resolveLayoutTypeId(member.ty.named) orelse continue;
                // Nested struct → array-split context is null (see above).
                const saved_ctx = self.array_layout_ctx;
                self.array_layout_ctx = null;
                defer self.array_layout_ctx = saved_ctx;
                try self.emitNestedStructLayoutInner(nested_type_id, nested_td.members, kind, member_is_row_major);
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
    fn emitArrayStrideRecursive(self: *Codegen, ty: ast.Type, kind: LayoutKind) !void {
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

        // Must match ensureType's `.array` key, which folds self.array_layout_ctx.
        // The layout pass keeps that context in sync with creation time (block
        // layout for direct members, null while recursing through a nested struct),
        // so the keys line up and we decorate the right array type id. `kind` still
        // drives the stride VALUE — so the different nesting levels of a single
        // block each get their own correct stride. NOTE this does NOT make a shared
        // nested struct's array correct across layouts: when the SAME named struct
        // is a member of both an std140 and an std430 block, its array type is
        // shared (unsplit) and the emitted_array_stride guard below keeps only the
        // first layout's stride — the documented cross-layout nested-struct
        // follow-up, not a per-level bug.
        const cache_key = arrayCacheKey(base_type_id, arr.size, self.array_layout_ctx);
        if (self.emitted_array_types.get(cache_key)) |array_type_id| {
            if (!self.emitted_array_stride.contains(array_type_id)) {
                const stride = self.layoutArrayStride(ty, kind);
                try self.emitDecorationSectionDecorate(array_type_id, @intFromEnum(spirv.Decoration.array_stride), stride);
                try self.emitted_array_stride.put(self.alloc, array_type_id, {});
            }
        }
        // Recurse into nested arrays
        if (arr.base.* == .array) {
            try self.emitArrayStrideRecursive(arr.base.*, kind);
        }
    }

    fn matrixRowCount(self: *Codegen, ty: ast.Type) u32 {
        _ = self;
        // matNxM = N columns, M rows; the square aliases matN == matNxN.
        return switch (ty) {
            .mat2, .mat2x2, .mat3x2, .mat4x2 => 2,
            .mat2x3, .mat3, .mat3x3, .mat4x3 => 3,
            .mat2x4, .mat3x4, .mat4, .mat4x4 => 4,
            else => 0,
        };
    }

    /// Byte stride between consecutive stored vectors of a matrix member under
    /// the given layout. For col_major the stored vectors are columns (span =
    /// row count); for row_major they are rows (span = column count). std430
    /// follows vector alignment (vec2 -> 8, vec3/vec4 -> 16); std140 always
    /// rounds the vector up to 16; scalar packs tightly at 4-byte components.
    /// This single source of truth keeps MatrixStride, layoutSize, and matrix
    /// alignment consistent (stride * vectorCount == reserved size).
    /// `span` is the vector length and is always 2, 3, or 4 for a real matrix.
    fn matrixMemberStride(self: *Codegen, span: u32, kind: LayoutKind) u32 {
        _ = self;
        return switch (kind) {
            .scalar => span * 4, // tight, component-aligned
            .std430 => if (span == 2) 8 else 16, // vec2 -> 8, vec3/vec4 -> 16
            .std140 => 16, // always vec4-aligned
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
        // First: emit OpSpecConstant for specialization constants (must come before types that reference them)
        var spec_iter = self.module.spec_constants.iterator();
        while (spec_iter.next()) |entry| {
            const sc = entry.value_ptr.*;
            // Reconstruct type from tag
            const TypeTag = @typeInfo(ast.Type).@"union".tag_type.?;
            const tag: TypeTag = @enumFromInt(sc.type_tag);
            const ty: ast.Type = switch (tag) {
                .int => .int,
                .uint => .uint,
                .float => .float,
                .bool => .bool,
                .int8 => .int8,
                .uint8 => .uint8,
                .int16 => .int16,
                .uint16 => .uint16,
                .float16 => .float16,
                .double => .double,
                .vec2 => .vec2,
                .vec3 => .vec3,
                .vec4 => .vec4,
                .ivec2 => .ivec2,
                .ivec3 => .ivec3,
                .ivec4 => .ivec4,
                .uvec2 => .uvec2,
                .uvec3 => .uvec3,
                .uvec4 => .uvec4,
                .mat2 => .mat2,
                .mat3 => .mat3,
                .mat4 => .mat4,
                .mat2x2 => .mat2x2,
                .mat2x3 => .mat2x3,
                .mat2x4 => .mat2x4,
                .mat3x2 => .mat3x2,
                .mat3x3 => .mat3x3,
                .mat3x4 => .mat3x4,
                .mat4x2 => .mat4x2,
                .mat4x3 => .mat4x3,
                .mat4x4 => .mat4x4,
                else => .int,
            };
            if (tag == .bool) {
                // OpSpecConstantTrue (48) / OpSpecConstantFalse (49) are
                // 3-word instructions with no literal payload — the truth
                // value is encoded in the opcode itself.
                const result_type_id = try self.ensureType(ty);
                const literal: u32 = if (sc.component_literals.len > 0) sc.component_literals[0] else 0;
                const op: spirv.Op = if (literal != 0) .SpecConstantTrue else .SpecConstantFalse;
                try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(op)));
                try self.emitTypeWord(result_type_id);
                try self.emitTypeWord(sc.result_id);
            } else if (ty.isVector() or ty.isMatrix()) {
                // Composite spec const: emit one OpSpecConstant per component
                // (each gets its own SpecId via the decoration loop), then
                // OpSpecConstantComposite groups them into the final value.
                //
                // For matrices: SPIR-V represents a matrix as a composite of
                // column vectors. We emit per-scalar OpSpecConstants and group
                // them into per-column OpSpecConstantComposites, then a final
                // OpSpecConstantComposite over the columns. The per-scalar
                // SpecId decorations let CPU-side override each scalar
                // independently via SpecId = spec_id + i.
                const elem_ty = ty.elementType();
                const elem_type_id = try self.ensureType(elem_ty);
                const n_components = ty.numComponents();

                // Emit per-scalar OpSpecConstants. component_ids[i] is the
                // result id of the i-th scalar component. Ownership transferred
                // to spec_const_component_ids below.
                const component_ids = try self.alloc.alloc(u32, n_components);
                errdefer self.alloc.free(component_ids);

                var i: u32 = 0;
                while (i < n_components) : (i += 1) {
                    const cid = self.allocId();
                    component_ids[i] = cid;
                    const lit: u32 = if (i < sc.component_literals.len) sc.component_literals[i] else 0;
                    try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.SpecConstant)));
                    try self.emitTypeWord(elem_type_id);
                    try self.emitTypeWord(cid);
                    try self.emitTypeWord(lit);
                    // Emit SpecId decoration to the decoration_section (spliced into
                    // the annotation section later, alongside other decorations).
                    try self.emitDecorationSectionDecorate(cid, @intFromEnum(spirv.Decoration.spec_id), sc.spec_id + i);
                }

                if (ty.isMatrix()) {
                    // Group scalars into per-column vec composites, then group
                    // columns into the matrix.
                    const col_ty = ty.columnType(); // vecR
                    const col_type_id = try self.ensureType(col_ty);
                    const n_cols = ty.numColumns();
                    const n_rows = col_ty.numComponents();
                    var col_ids = try self.alloc.alloc(u32, n_cols);
                    defer self.alloc.free(col_ids);

                    var c: u32 = 0;
                    while (c < n_cols) : (c += 1) {
                        const col_id = self.allocId();
                        col_ids[c] = col_id;
                        const header = spirv.encodeInstructionHeader(@as(u16, 3 + @as(u16, @intCast(n_rows))), @intFromEnum(spirv.Op.SpecConstantComposite));
                        try self.emitTypeWord(header);
                        try self.emitTypeWord(col_type_id);
                        try self.emitTypeWord(col_id);
                        var r: u32 = 0;
                        while (r < n_rows) : (r += 1) {
                            try self.emitTypeWord(component_ids[c * n_rows + r]);
                        }
                    }

                    const mat_type_id = try self.ensureType(ty);
                    const header_m = spirv.encodeInstructionHeader(@as(u16, 3 + @as(u16, @intCast(n_cols))), @intFromEnum(spirv.Op.SpecConstantComposite));
                    try self.emitTypeWord(header_m);
                    try self.emitTypeWord(mat_type_id);
                    try self.emitTypeWord(sc.result_id);
                    var k: u32 = 0;
                    while (k < n_cols) : (k += 1) {
                        try self.emitTypeWord(col_ids[k]);
                    }
                } else {
                    // Vector: single OpSpecConstantComposite over the scalars.
                    const vec_type_id = try self.ensureType(ty);
                    const header = spirv.encodeInstructionHeader(@as(u16, 3 + @as(u16, @intCast(n_components))), @intFromEnum(spirv.Op.SpecConstantComposite));
                    try self.emitTypeWord(header);
                    try self.emitTypeWord(vec_type_id);
                    try self.emitTypeWord(sc.result_id);
                    var j: u32 = 0;
                    while (j < n_components) : (j += 1) {
                        try self.emitTypeWord(component_ids[j]);
                    }
                }

                // Stash per-component ids on the codegen for SpecId decoration emission.
                // Ownership of `component_ids` transfers to the map; deinit frees it.
                try self.spec_const_component_ids.put(self.alloc, sc.result_id, component_ids);
            } else {
                // Scalar (non-bool) spec constant.
                const result_type_id = try self.ensureType(ty);
                const literal: u32 = if (sc.component_literals.len > 0) sc.component_literals[0] else 0;
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.SpecConstant)));
                try self.emitTypeWord(result_type_id);
                try self.emitTypeWord(sc.result_id);
                try self.emitTypeWord(literal);
            }
            // DO NOT cache spec constants in emitted_constants — they would collide with
            // regular OpConstant values and cause struct AccessChain to use spec constants
            // as indices (which is illegal in SPIR-V).
            // Spec constant references are resolved via constant_alias in codegen.
        }
        // M3.5: emit literal-const operands for OpSpecConstantOp (these
        // are regular OpConstants that any OpSpecConstantOp may reference
        // alongside spec consts). Cache them in emitted_constants so any
        // function-body reference to the same value reuses the id.
        for (self.module.spec_op_literals) |lit| {
            const TypeTagL = @typeInfo(ast.Type).@"union".tag_type.?;
            const tagL: TypeTagL = @enumFromInt(lit.type_tag);
            const tyL: ast.Type = switch (tagL) {
                .int => .int,
                .uint => .uint,
                .float => .float,
                else => .int,
            };
            const type_id_L = try self.ensureType(tyL);
            const cache_key_L = (@as(u64, type_id_L) << 32) | @as(u64, lit.value);
            if (self.emitted_constants.get(cache_key_L)) |existing| {
                if (lit.result_id != existing) {
                    try self.constant_alias.put(self.alloc, lit.result_id, existing);
                }
            } else {
                try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
                try self.emitTypeWord(type_id_L);
                try self.emitTypeWord(lit.result_id);
                try self.emitTypeWord(lit.value);
                try self.emitted_constants.put(self.alloc, cache_key_L, lit.result_id);
            }
        }
        // M3.5: emit OpSpecConstantOp instructions. Operands always come
        // from earlier-emitted spec consts / spec const ops / literal
        // consts, so the insertion-ordered StringArrayHashMap gives the
        // correct topological order (semantic builds inner expressions
        // before outer ones, so a forward iteration is dependency-safe).
        var sco_iter = self.module.spec_constant_ops.iterator();
        while (sco_iter.next()) |entry| {
            const sco = entry.value_ptr.*;
            const TypeTagS = @typeInfo(ast.Type).@"union".tag_type.?;
            const tagS: TypeTagS = @enumFromInt(sco.type_tag);
            const tyS: ast.Type = switch (tagS) {
                .int => .int,
                .uint => .uint,
                .float => .float,
                else => .int,
            };
            const result_type_id = try self.ensureType(tyS);
            const n_ops: u16 = @intCast(sco.operand_ids.len);
            // wc = 4 + N (header + result_type + result_id + opcode-literal + N operands)
            const wc: u16 = 4 + n_ops;
            try self.emitTypeWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.SpecConstantOp)));
            try self.emitTypeWord(result_type_id);
            try self.emitTypeWord(sco.result_id);
            try self.emitTypeWord(sco.spirv_opcode);
            for (sco.operand_ids) |op_id| {
                // Resolve constant_alias in case an operand was deduped.
                const real_id = if (self.constant_alias.get(op_id)) |aliased| aliased else op_id;
                try self.emitTypeWord(real_id);
            }
        }
        // Pre-scan ALL function bodies for constants and emit them.
        // This ensures constants defined in one function are available when
        // referenced by another function (cross-function const_cache reuse).
        for (self.module.functions) |func| {
            for (func.body) |inst| {
                switch (inst.tag) {
                    .constant_float => {
                        const val: f32 = switch (inst.operands[0]) {
                            .literal_float => |v| v,
                            .literal_int => |v| @floatFromInt(v),
                            else => continue,
                        };
                        const float_type_id = try self.ensureType(.float);
                        const cache_key = (@as(u64, float_type_id) << 32) | @as(u64, @as(u32, @bitCast(val)));
                        const ir_id = inst.result_id orelse continue;
                        if (self.emitted_constants.get(cache_key)) |existing_id| {
                            if (ir_id != existing_id) {
                                try self.constant_alias.put(self.alloc, ir_id, existing_id);
                            }
                        } else {
                            try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
                            try self.emitTypeWord(float_type_id);
                            try self.emitTypeWord(ir_id);
                            try self.emitTypeWord(@as(u32, @bitCast(val)));
                            try self.emitted_constants.put(self.alloc, cache_key, ir_id);
                        }
                    },
                    .constant_int => {
                        const val: u32 = switch (inst.operands[0]) {
                            .literal_int => |v| v,
                            else => continue,
                        };
                        const int_type_id = try self.ensureType(inst.ty);
                        const cache_key = (@as(u64, int_type_id) << 32) | @as(u64, val);
                        const ir_id = inst.result_id orelse continue;
                        if (self.emitted_constants.get(cache_key)) |existing_id| {
                            if (ir_id != existing_id) {
                                try self.constant_alias.put(self.alloc, ir_id, existing_id);
                            }
                        } else {
                            try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Constant)));
                            try self.emitTypeWord(int_type_id);
                            try self.emitTypeWord(ir_id);
                            try self.emitTypeWord(val);
                            try self.emitted_constants.put(self.alloc, cache_key, ir_id);
                        }
                    },
                    .constant_bool => {
                        const val: u32 = switch (inst.operands[0]) {
                            .literal_int => |v| v,
                            else => continue,
                        };
                        const bool_type_id = try self.ensureType(.bool);
                        const cache_key = (@as(u64, bool_type_id) << 32) | @as(u64, val);
                        const ir_id = inst.result_id orelse continue;
                        if (self.emitted_constants.get(cache_key)) |existing_id| {
                            if (ir_id != existing_id) {
                                try self.constant_alias.put(self.alloc, ir_id, existing_id);
                            }
                        } else {
                            const opcode: u16 = if (val != 0) @intFromEnum(spirv.Op.ConstantTrue) else @intFromEnum(spirv.Op.ConstantFalse);
                            try self.emitTypeWord(spirv.encodeInstructionHeader(3, opcode));
                            try self.emitTypeWord(bool_type_id);
                            try self.emitTypeWord(ir_id);
                            try self.emitted_constants.put(self.alloc, cache_key, ir_id);
                        }
                    },
                    else => {},
                }
            }
        }
        // Design A — module-scope const-array global initializers. Replay the
        // self-contained constant instructions (scalar OpConstants then the
        // OpConstantComposite, in dependency order) into the constants section,
        // BEFORE emitGlobals runs, so each Private OpVariable can reference its
        // composite as a word-count-5 initializer without a forward reference.
        // emitInstruction here (in_functions == false) routes to the main
        // stream and dedups scalars via emitted_constants/constant_alias, so a
        // value shared with a function body is emitted once.
        for (self.module.global_init_constants) |inst| {
            try self.emitInstruction(inst);
        }
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
        // Pre-pass (#183): record each storage-image global's explicit
        // `layout(rgbaN)` format keyed by the variable's result_id. Both the
        // scalar `image2D` and the array-of-image (`image2D arr[N]`) forms are
        // captured here, recursing through the array base. The format is later
        // threaded into the OpVariable pointer type and into loads of the image
        // via `ensureStorageImagePointerType` / the `.load` arm, so each image
        // keeps its OWN format even when several share the same GLSL enum.
        // (The format-blind `emitted_types` would otherwise collapse them and
        // drop the 2nd image's Format — that was the bug.)
        for (self.module.globals) |global| {
            const layout = global.layout orelse continue;
            const fmt = layout.image_format orelse continue;
            var base_ty = global.ty;
            while (base_ty == .array) base_ty = base_ty.array.base.*;
            if (!base_ty.isStorageImage()) continue;
            try self.storage_image_format_by_ptr.put(self.alloc, global.result_id, fmt);
        }
        for (self.module.globals) |global| {
            // Storage-image globals get a format-aware pointer type so each
            // variable carries its own `layout(rgbaN)` Format (#183). Others
            // resolve through the generic, format-blind path.
            if (self.storage_image_format_by_ptr.get(global.result_id)) |fmt| {
                _ = try self.ensureStorageImagePointerType(global.ty, fmt, global.storage_class);
            } else {
                _ = try self.ensureType(global.ty);
                _ = try self.ensurePointerType(global.ty, global.storage_class);
            }
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
            if (global.result_id == 0) continue; // Skip unassigned globals

            // NOTE: M5.2 v3 — the mesh-shader per-vertex/per-primitive builtins
            // (gl_MeshPerVertexEXT, gl_PrimitiveTriangleIndicesEXT, …) used
            // to be wrapped into OpTypeArray here at codegen time because
            // semantic registered them as scalar types. Semantic now
            // registers them as proper `.array` types sized from the parsed
            // layout, so the generic ensurePointerType path emits the right
            // OpTypeArray for free. Wrapping again here would double-wrap.
            //
            // User-declared mesh outputs (`layout(location=N) out vec4 foo[];`)
            // arrive with array size 0 (the GLSL `[]` syntax = unsized in
            // source, deferred to layout). For Vulkan they must be sized
            // arrays — OpTypeRuntimeArray is not allowed for plain Output
            // storage class. Patch the size from the mesh layout here
            // (max_vertices for per-vertex outputs, max_primitives for
            // perprimitiveEXT-qualified outputs).
            var effective_ty = global.ty;
            var patched_array: ast.Type = undefined;
            var patched_base: ast.Type = undefined;
            if (global.storage_class == .output and effective_ty == .array and effective_ty.array.size == 0) {
                const mesh_size: ?u32 = if (global.qualifier.is_perprimitive_ext)
                    self.module.mesh_max_primitives
                else
                    self.module.mesh_max_vertices;
                if (mesh_size) |sz| {
                    // Construct a sized copy on the stack — only used for
                    // ensurePointerType below, so the slice lifetime is fine.
                    patched_base = effective_ty.array.base.*;
                    patched_array = .{ .array = .{ .base = &patched_base, .size = sz } };
                    effective_ty = patched_array;
                }
            }

            const ptr_type_id = if (self.storage_image_format_by_ptr.get(global.result_id)) |fmt|
                try self.ensureStorageImagePointerType(effective_ty, fmt, global.storage_class)
            else
                try self.ensurePointerType(effective_ty, global.storage_class);
            // Design A — a module-scope `const` global lowered to a Private
            // OpVariable carries its folded constant-composite as an initializer
            // (word-count 5). The composite was emitted in emitTypesAndConstants
            // (before this point) so the reference is backward, not forward.
            // Guard on Private storage: only Private/Function/Output may take an
            // initializer, and only Private globals are produced this way.
            if (global.initializer_id != null and global.storage_class == .private) {
                const init_id = self.constant_alias.get(global.initializer_id.?) orelse global.initializer_id.?;
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.Variable)));
                try self.emitWord(ptr_type_id);
                try self.emitWord(global.result_id);
                try self.emitWord(@intFromEnum(global.storage_class));
                try self.emitWord(init_id);
                continue;
            }
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
        defer {
            for (func_infos.items) |info| {
                if (info.param_type_ids.len > 0) self.alloc.free(info.param_type_ids);
            }
            func_infos.deinit(self.alloc);
        }
        for (self.module.functions) |func| {
            const return_type_id = try self.ensureType(func.return_type);
            var param_type_ids = try std.ArrayList(u32).initCapacity(self.alloc, func.params.len);
            for (func.params) |param| {
                const is_mutable = if (param.qualifier) |q| (q.is_inout or q.is_out) else false;
                if (is_mutable) {
                    const ptr_type_id = try self.ensurePointerType(param.ty, .function);
                    try param_type_ids.append(self.alloc, ptr_type_id);
                } else {
                    try param_type_ids.append(self.alloc, try self.ensureType(param.ty));
                }
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

            // Clear per-function caches
            self.access_chain_cache.clearRetainingCapacity();
            self.codegen_pure_cache.clearRetainingCapacity();

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

    /// Extract the Dref (depth comparison value) and the shrunk sampling
    /// coordinate for a shadow-sampler image-sample-dref instruction.
    ///
    /// GLSL packs the Dref as the last component of the coordinate; SPIR-V's
    /// OpImageSampleDref* ops take the Dref as a separate operand and a
    /// coordinate with that component removed. Both the OpCompositeExtract for
    /// the Dref and the coordinate shrink (OpCompositeExtract / OpVectorShuffle)
    /// are cached in codegen_pure_cache so repeated uses of the same coordinate
    /// reuse ids. This single-sources the shadow-sampler edge cases shared by
    /// the image_sample_dref and image_sample_dref_explicit_lod arms
    /// (sampler1d_shadow / samplerCubeArrayShadow currently fall to the
    /// `else => 3 / .vec3` branch).
    fn emitDrefAndShrunkCoord(self: *Codegen, inst_ty: ast.Type, coord_id: u32) !struct { dref_id: u32, shrunk_coord_id: u32 } {
        const float_id = try self.ensureType(.float);
        // Determine last component index based on sampler type
        const last_idx: u32 = switch (inst_ty) {
            .sampler2d_shadow => 2, // vec3(u,v,dref) → extract [2]
            .sampler2d_array_shadow => 3, // vec4(u,v,layer,dref) → extract [3]
            .sampler_cube_shadow => 3, // vec4(u,v,z,dref) → extract [3]
            .sampler1d_shadow => 1, // vec2(u,dref) → extract [1]
            else => 3,
        };
        // Extract Dref from last component of coord (with caching)
        const dref_key: u64 = @as(u64, coord_id) *% 31 +% @as(u64, last_idx) + 0x1000;
        const dref_id: u32 = if (self.codegen_pure_cache.get(dref_key)) |cached| cached else blk: {
            const new_id = self.allocId();
            try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
            try self.emitWord(float_id);
            try self.emitWord(new_id);
            try self.emitWord(coord_id);
            try self.emitWord(last_idx);
            self.codegen_pure_cache.put(self.alloc, dref_key, new_id) catch {};
            break :blk new_id;
        };
        // Shrink coordinate (with caching)
        const shrink_ty: ast.Type = switch (inst_ty) {
            .sampler2d_shadow => .vec2, // vec3 → vec2
            .sampler2d_array_shadow => .vec3, // vec4 → vec3
            .sampler_cube_shadow => .vec3, // vec4 → vec3
            .sampler1d_shadow => .float, // vec2 → float
            else => .vec3,
        };
        const shrink_type_id = try self.ensureType(shrink_ty);
        const shrink_key: u64 = @as(u64, coord_id) *% 31 +% @as(u64, @intFromEnum(shrink_ty)) + 0x2000;
        const shrunk_coord_id: u32 = if (shrink_ty == .float) blk: {
            // shrink_ty == .float here, so shrink_type_id is already the float type id.
            if (self.codegen_pure_cache.get(shrink_key)) |cached| break :blk cached;
            const new_id = self.allocId();
            try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
            try self.emitWord(shrink_type_id);
            try self.emitWord(new_id);
            try self.emitWord(coord_id);
            try self.emitWord(0);
            self.codegen_pure_cache.put(self.alloc, shrink_key, new_id) catch {};
            break :blk new_id;
        } else blk: {
            if (self.codegen_pure_cache.get(shrink_key)) |cached| break :blk cached;
            const new_id = self.allocId();
            const num_comp: u32 = switch (shrink_ty) {
                .vec2 => 2,
                .vec3 => 3,
                else => 3,
            };
            try self.emitWord(spirv.encodeInstructionHeader(@as(u16, @intCast(5 + num_comp)), @intFromEnum(spirv.Op.VectorShuffle)));
            try self.emitWord(shrink_type_id);
            try self.emitWord(new_id);
            try self.emitWord(coord_id);
            try self.emitWord(coord_id);
            for (0..num_comp) |i| try self.emitWord(@intCast(i));
            self.codegen_pure_cache.put(self.alloc, shrink_key, new_id) catch {};
            break :blk new_id;
        };
        return .{ .dref_id = dref_id, .shrunk_coord_id = shrunk_coord_id };
    }

    fn emitInstruction(self: *Codegen, inst: ir.Instruction) !void {
        // Resolve null result_type from ast type
        var resolved = inst;
        // #183: a `.load` of a storage image must resolve its result type to the
        // FORMAT-AWARE OpTypeImage of the source variable, not the format-blind
        // `ensureType(.image2d)` (which would emit a fresh Unknown-format image
        // that also fails to match the variable's pointee type). Resolve the
        // declared format from the loaded pointer (operand 0).
        if (resolved.result_type == null and resolved.result_id != null and
            resolved.tag == .load and inst.ty.isStorageImage())
        {
            const ptr_id = self.operandId(resolved, 0);
            if (self.storageImageFormatForPtr(ptr_id)) |fmt| {
                resolved.result_type = try self.ensureStorageImageType(inst.ty, fmt);
            }
        }
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
            .spec_constant => return, // Emitted during emitTypesAndConstants
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
                        const cache_key = (@as(u64, bool_type_id) << 32) | @as(u64, val);
                        if (self.emitted_constants.get(cache_key)) |existing_id| {
                            const ir_id = resolved.result_id orelse return;
                            if (ir_id != existing_id) {
                                try self.constant_alias.put(self.alloc, ir_id, existing_id);
                            }
                            return;
                        }
                        const op: spirv.Op = if (val != 0) .ConstantTrue else .ConstantFalse;
                        try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(op)));
                        try self.emitTypeWord(bool_type_id);
                        const ir_id = resolved.result_id orelse return;
                        try self.emitTypeWord(ir_id);
                        try self.emitted_constants.put(self.alloc, cache_key, ir_id);
                    },
                    else => {},
                }
                return;
            },
            .constant_composite => {
                // OpConstantComposite — must be emitted in type section
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const wc: u16 = 3 + @as(u16, @intCast(resolved.operands.len));
                try self.emitTypeWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.ConstantComposite)));
                try self.emitTypeWord(result_type_id);
                try self.emitTypeWord(result_id);
                for (resolved.operands) |op| {
                    try self.emitTypeWord(self.operandValue(op));
                }
                return;
            },
            .control_barrier => {
                // OpControlBarrier: Execution Scope <id>, Memory Scope <id>, Memory Semantics <id>
                const scope = self.operandId(resolved, 0);
                const mem_scope = self.operandId(resolved, 1);
                const semantics = self.operandId(resolved, 2);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.ControlBarrier)));
                try self.emitWord(scope);
                try self.emitWord(mem_scope);
                try self.emitWord(semantics);
            },
            .memory_barrier => {
                // OpMemoryBarrier: Memory Scope <id>, Memory Semantics <id>
                const scope = self.operandId(resolved, 0);
                const semantics = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.MemoryBarrier)));
                try self.emitWord(scope);
                try self.emitWord(semantics);
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
                const ptr_id_raw = self.operandId(resolved, 0);
                const ptr_id = self.constant_alias.get(ptr_id_raw) orelse ptr_id_raw;
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
                    // Interface block bool/bvec member: load as uint/uvec, convert to bool/bvec
                    if (self.interface_bool_ptrs.get(ptr_id)) |original_ty| {
                        if (original_ty == .bool) {
                            const uint_type_id = try self.ensureType(.uint);
                            const bool_type_id = try self.ensureType(.bool);
                            const uint_0 = try self.emitIntConstant(0);
                            // Load as uint into temp
                            const temp_uint_id = self.allocId();
                            try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Load)));
                            try self.emitWord(uint_type_id);
                            try self.emitWord(temp_uint_id);
                            try self.emitWord(ptr_id);
                            // Convert uint -> bool: result_id = OpINotEqual(bool, temp_uint, uint_0)
                            try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.INotEqual)));
                            try self.emitWord(bool_type_id);
                            try self.emitWord(result_id);
                            try self.emitWord(temp_uint_id);
                            try self.emitWord(uint_0);
                            return;
                        } else if (original_ty == .bvec2 or original_ty == .bvec3 or original_ty == .bvec4) {
                            const n: u32 = switch (original_ty) {
                                .bvec2 => 2,
                                .bvec3 => 3,
                                .bvec4 => 4,
                                else => unreachable,
                            };
                            const uvec_type_id = try self.ensureType(switch (original_ty) { .bvec2 => ast.Type.uvec2, .bvec3 => ast.Type.uvec3, .bvec4 => ast.Type.uvec4, else => unreachable });
                            const bvec_type_id = try self.ensureType(original_ty);
                            const uint_0 = try self.emitIntConstant(0);
                            // Load as uvec into temp
                            const temp_uvec_id = self.allocId();
                            try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Load)));
                            try self.emitWord(uvec_type_id);
                            try self.emitWord(temp_uvec_id);
                            try self.emitWord(ptr_id);
                            // Create uvec_0 constant
                            const uvec_const_key = (@as(u64, uvec_type_id) << 32) | 0;
                            const uvec_0_id = if (self.emitted_constants.get(uvec_const_key)) |cached| cached else blk: {
                                const uid = self.allocId();
                                try self.emitWord(spirv.encodeInstructionHeader(@as(u16, 2) + @as(u16, @intCast(n)), @intFromEnum(spirv.Op.ConstantComposite)));
                                try self.emitWord(uvec_type_id);
                                try self.emitWord(uid);
                                for (0..n) |_| {
                                    try self.emitWord(uint_0);
                                }
                                try self.emitted_constants.put(self.alloc, uvec_const_key, uid);
                                break :blk uid;
                            };
                            // Convert uvec -> bvec: OpINotEqual(bvec, temp_uvec, uvec_0)
                            try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.INotEqual)));
                            try self.emitWord(bvec_type_id);
                            try self.emitWord(result_id);
                            try self.emitWord(temp_uvec_id);
                            try self.emitWord(uvec_0_id);
                            return;
                        }
                    }
                }
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Load)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(ptr_id);
            },
            .store => {
                const ptr_id_raw = self.operandId(resolved, 0);
                const ptr_id = self.constant_alias.get(ptr_id_raw) orelse ptr_id_raw;
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
                    // Interface block bool/bvec member: convert before store
                    if (self.interface_bool_ptrs.get(ptr_id)) |original_ty| {
                        if (original_ty == .bool) {
                            const uint_type_id = try self.ensureType(.uint);
                            const uint_0 = try self.emitIntConstant(0);
                            const uint_1 = try self.emitIntConstant(1);
                            // bool -> uint: OpSelect(uint, bool_val, uint_1, uint_0)
                            const uint_val_id = self.allocId();
                            try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.Select)));
                            try self.emitWord(uint_type_id);
                            try self.emitWord(uint_val_id);
                            try self.emitWord(val_id);
                            try self.emitWord(uint_1);
                            try self.emitWord(uint_0);
                            // Store the uint value
                            try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.Store)));
                            try self.emitWord(ptr_id);
                            try self.emitWord(uint_val_id);
                            return;
                        } else if (original_ty == .bvec2 or original_ty == .bvec3 or original_ty == .bvec4) {
                            const n: u32 = switch (original_ty) {
                                .bvec2 => 2,
                                .bvec3 => 3,
                                .bvec4 => 4,
                                else => unreachable,
                            };
                            const uvec_type_id = try self.ensureType(switch (original_ty) { .bvec2 => ast.Type.uvec2, .bvec3 => ast.Type.uvec3, .bvec4 => ast.Type.uvec4, else => unreachable });
                            const uint_0 = try self.emitIntConstant(0);
                            const uint_1 = try self.emitIntConstant(1);
                            // Create uvec_0 and uvec_1 constants
                            const uvec_0_key = (@as(u64, uvec_type_id) << 32) | 0;
                            const uvec_0_id = if (self.emitted_constants.get(uvec_0_key)) |c| c else blk: {
                                const uid = self.allocId();
                                try self.emitWord(spirv.encodeInstructionHeader(@as(u16, 2) + @as(u16, @intCast(n)), @intFromEnum(spirv.Op.ConstantComposite)));
                                try self.emitWord(uvec_type_id);
                                try self.emitWord(uid);
                                for (0..n) |_| try self.emitWord(uint_0);
                                try self.emitted_constants.put(self.alloc, uvec_0_key, uid);
                                break :blk uid;
                            };
                            const uvec_1_key = (@as(u64, uvec_type_id) << 32) | 1;
                            const uvec_1_id = if (self.emitted_constants.get(uvec_1_key)) |c| c else blk: {
                                const uid = self.allocId();
                                try self.emitWord(spirv.encodeInstructionHeader(@as(u16, 2) + @as(u16, @intCast(n)), @intFromEnum(spirv.Op.ConstantComposite)));
                                try self.emitWord(uvec_type_id);
                                try self.emitWord(uid);
                                for (0..n) |_| try self.emitWord(uint_1);
                                try self.emitted_constants.put(self.alloc, uvec_1_key, uid);
                                break :blk uid;
                            };
                            // bvec -> uvec: OpSelect(uvec, bvec_val, uvec_1, uvec_0)
                            const uvec_val_id = self.allocId();
                            try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.Select)));
                            try self.emitWord(uvec_type_id);
                            try self.emitWord(uvec_val_id);
                            try self.emitWord(val_id);
                            try self.emitWord(uvec_1_id);
                            try self.emitWord(uvec_0_id);
                            // Store the uvec value
                            try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.Store)));
                            try self.emitWord(ptr_id);
                            try self.emitWord(uvec_val_id);
                            return;
                        }
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
            .fadd => try self.emitFloatBinOp(spirv.Op.FAdd, resolved),
            .fsub => try self.emitFloatBinOp(spirv.Op.FSub, resolved),
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
            .convert_narrow => try self.emitUnaryOp(spirv.Op.SConvert, resolved),
            .convert_widen => try self.emitUnaryOp(spirv.Op.SConvert, resolved),
            .convert_ftof => try self.emitUnaryOp(spirv.Op.FConvert, resolved),
            .convert_itof => try self.emitUnaryOp(spirv.Op.ConvertSToF, resolved),
            .bitcast => try self.emitUnaryOp(spirv.Op.Bitcast, resolved),
            .convert_utof => try self.emitUnaryOp(spirv.Op.ConvertUToF, resolved),
            .convert_itu => try self.emitUnaryOp(spirv.Op.Bitcast, resolved),
            .bool_to_float, .bool_to_int, .bool_to_uint => {
                // bool → numeric: use OpSelect(T, bool, T(1), T(0))
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const cond_id = self.operandId(resolved, 0);
                const one_id: u32 = switch (resolved.tag) {
                    .bool_to_float => try self.emitFloatConstant(1.0),
                    .bool_to_int => try self.emitSignedIntConstant(1),
                    .bool_to_uint => try self.emitIntConstant(1),
                    else => return,
                };
                const zero_id: u32 = switch (resolved.tag) {
                    .bool_to_float => try self.emitFloatConstant(0.0),
                    .bool_to_int => try self.emitSignedIntConstant(0),
                    .bool_to_uint => try self.emitIntConstant(0),
                    else => return,
                };
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.Select)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(cond_id);
                try self.emitWord(one_id);
                try self.emitWord(zero_id);
            },
            .int_to_bool, .uint_to_bool => {
                // int/uint → bool: use OpINotEqual(bool, value, 0)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const val_id = self.operandId(resolved, 0);
                const zero_id: u32 = if (resolved.tag == .int_to_bool) try self.emitSignedIntConstant(0) else try self.emitIntConstant(0);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.INotEqual)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(val_id);
                try self.emitWord(zero_id);
            },
            .float_to_bool => {
                // float → bool: use OpFOrdNotEqual(bool, value, 0.0)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const val_id = self.operandId(resolved, 0);
                const zero_id = try self.emitFloatConstant(0.0);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.FOrdNotEqual)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(val_id);
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
                    // Check cache first
                    const buf_cache_key = (@as(u64, base_id_val) << 32) | @as(u64, index_id);
                    if (self.access_chain_cache.get(buf_cache_key)) |cached_loaded| {
                        // Reuse existing buffer reference load result
                        try self.constant_alias.put(self.alloc, result_id, cached_loaded);
                        try self.ptr_storage_class.put(self.alloc, cached_loaded, .physical_storage_buffer);
                    } else {
                        // Access chain: get a pointer to the PhysicalStorageBuffer pointer member
                        const struct_id = try self.ensureType(inst.ty);
                        const phys_ptr_key = (@as(u64, struct_id) << 32) | @as(u64, 5349);
                        const phys_ptr_id = self.emitted_ptr_types.get(phys_ptr_key) orelse struct_id;
                        // Create pointer-to-pointer type: StorageBuffer -> PhysicalStorageBuffer pointer
                        const ptr_to_ptr_key = (@as(u64, phys_ptr_id) << 32) | @as(u64, @intFromEnum(sc));
                        const ptr_type_id = if (self.emitted_ptr_types.get(ptr_to_ptr_key)) |ptr_cached| ptr_cached else blk: {
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
                        // If the AccessChain base was PhysSB, the result pointer is also PhysSB
                        // and the load needs Aligned operand
                        const need_aligned = (self.ptr_storage_class.get(result_id) != null and
                            self.ptr_storage_class.get(result_id).? == .physical_storage_buffer);
                        const loaded_id = self.allocId();
                        if (need_aligned) {
                            try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.Load)));
                            try self.emitWord(phys_ptr_id);
                            try self.emitWord(loaded_id);
                            try self.emitWord(result_id);
                            try self.emitWord(2); // Aligned memory operand bit
                            try self.emitWord(16); // alignment
                        } else {
                            try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.Load)));
                            try self.emitWord(phys_ptr_id);
                            try self.emitWord(loaded_id);
                            try self.emitWord(result_id);
                        }
                        // Alias the result_id to the loaded pointer for subsequent access chains
                        try self.constant_alias.put(self.alloc, result_id, loaded_id);
                        // Track the loaded pointer as PhysicalStorageBuffer
                        try self.ptr_storage_class.put(self.alloc, loaded_id, .physical_storage_buffer);
                        // Cache the loaded result
                        try self.access_chain_cache.put(self.alloc, buf_cache_key, loaded_id);
                    }
                } else {
                    // For interface block members, convert bool/bvec to uint/uvec
                    var access_ty = inst.ty;
                    const is_interface_bool = (sc == .uniform or sc == .storage_buffer) and
                        (inst.ty == .bool or inst.ty == .bvec2 or inst.ty == .bvec3 or inst.ty == .bvec4);
                    if (sc == .uniform or sc == .storage_buffer) {
                        access_ty = switch (access_ty) {
                            .bool => .uint,
                            .bvec2 => .uvec2,
                            .bvec3 => .uvec3,
                            .bvec4 => .uvec4,
                            else => access_ty,
                        };
                    }
                    // #183: an access chain into an array-of-storage-image
                    // (`arr[i]`) must produce a pointer to the FORMAT-AWARE
                    // element image type, and the resulting pointer must itself
                    // be tracked so the subsequent `.load` resolves the same
                    // format-aware image. Without this the element type would be
                    // the format-blind Unknown image.
                    const storage_img_fmt: ?ast.ImageFormat = if (access_ty.isStorageImage())
                        self.storageImageFormatForPtr(base_id_val)
                    else
                        null;
                    const ptr_type_id = if (storage_img_fmt) |fmt| blk: {
                        const elem_id = try self.ensureStorageImageType(access_ty, fmt);
                        const ptr_key: u64 = (@as(u64, elem_id) << 32) | @as(u64, @intFromEnum(sc));
                        if (self.emitted_ptr_types.get(ptr_key)) |cached| break :blk cached;
                        const new_ptr_id = self.allocId();
                        try self.emitTypeWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.TypePointer)));
                        try self.emitTypeWord(new_ptr_id);
                        try self.emitTypeWord(@intFromEnum(sc));
                        try self.emitTypeWord(elem_id);
                        try self.emitted_ptr_types.put(self.alloc, ptr_key, new_ptr_id);
                        break :blk new_ptr_id;
                    } else try self.ensurePointerType(access_ty, sc);
                    // Propagate the element's format to the access-chain result so
                    // the following load is format-aware too.
                    if (storage_img_fmt) |fmt| {
                        try self.storage_image_format_by_ptr.put(self.alloc, result_id, fmt);
                    }
                    // Check if we've already computed this AccessChain
                    const cache_key = (@as(u64, base_id_val) << 32) | @as(u64, index_id);
                    if (self.access_chain_cache.get(cache_key)) |cached_result| {
                        // Reuse existing result, alias it
                        try self.constant_alias.put(self.alloc, result_id, cached_result);
                        try self.ptr_storage_class.put(self.alloc, cached_result, sc);
                        if (is_interface_bool) {
                            try self.interface_bool_ptrs.put(self.alloc, cached_result, inst.ty);
                        }
                    } else {
                        try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.AccessChain)));
                        try self.emitWord(ptr_type_id);
                        try self.emitWord(result_id);
                        try self.emitWord(base_id_val);
                        try self.emitWord(index_id);
                        try self.access_chain_cache.put(self.alloc, cache_key, result_id);
                        if (is_interface_bool) {
                            try self.interface_bool_ptrs.put(self.alloc, result_id, inst.ty);
                        }
                    }
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
                // Check cache for duplicate AccessChain
                const cache_key = (@as(u64, base_id) << 32) | @as(u64, index_const_id);
                if (self.access_chain_cache.get(cache_key)) |cached_result| {
                    try self.constant_alias.put(self.alloc, result_id, cached_result);
                } else {
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.AccessChain)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(base_id);
                    try self.emitWord(index_const_id);
                    try self.access_chain_cache.put(self.alloc, cache_key, result_id);
                }
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
                if (resolved.operands.len >= 4) {
                    // textureLodOffset: sampler, coord, lod, offset → Lod|ConstOffset
                    const offset_id = self.operandId(resolved, 3);
                    try self.emitWord(spirv.encodeInstructionHeader(8, @intFromEnum(spirv.Op.ImageSampleExplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(10); // Image Operands Mask: Lod (bit 1) | ConstOffset (bit 3)
                    try self.emitWord(lod_id);
                    try self.emitWord(offset_id);
                } else {
                    // textureLod: sampler, coord, lod → Lod
                    try self.emitWord(spirv.encodeInstructionHeader(7, @intFromEnum(spirv.Op.ImageSampleExplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(2); // Image Operands Mask: Lod
                    try self.emitWord(lod_id);
                }
            },
            .image_sample_grad => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const dx_id = self.operandId(resolved, 2);
                const dy_id = self.operandId(resolved, 3);
                // textureGrad: sampler, coord, dx, dy → Grad
                try self.emitWord(spirv.encodeInstructionHeader(8, @intFromEnum(spirv.Op.ImageSampleExplicitLod)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(coord_id);
                try self.emitWord(4); // Image Operands Mask: Grad (bit 2)
                try self.emitWord(dx_id);
                try self.emitWord(dy_id);
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
                const dref = try self.emitDrefAndShrunkCoord(inst.ty, coord_id);
                const dref_id = dref.dref_id;
                const shrunk_coord_id = dref.shrunk_coord_id;
                // Emit the Dref instruction
                if (resolved.operands.len >= 4) {
                    // textureOffset(shadow, coord, offset, bias) → Bias|ConstOffset
                    const offset_id = self.operandId(resolved, 2);
                    const bias_id = self.operandId(resolved, 3);
                    try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.ImageSampleDrefImplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(shrunk_coord_id);
                    try self.emitWord(dref_id);
                    try self.emitWord(9); // Image Operand Bias|ConstOffset (bit 0 | bit 3)
                    try self.emitWord(bias_id);
                    try self.emitWord(offset_id);
                } else if (resolved.operands.len >= 3 and inst.ty != .sampler_cube_array_shadow) {
                    // texture(shadow, coord, bias) → Bias
                    const bias_id = self.operandId(resolved, 2);
                    try self.emitWord(spirv.encodeInstructionHeader(8, @intFromEnum(spirv.Op.ImageSampleDrefImplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(shrunk_coord_id);
                    try self.emitWord(dref_id);
                    try self.emitWord(1); // Image Operand Bias (bit 0)
                    try self.emitWord(bias_id);
                } else {
                    try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageSampleDrefImplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(shrunk_coord_id);
                    try self.emitWord(dref_id);
                }
                }
            },
            .image_sample_dref_explicit_lod => {
                // OpImageSampleDrefExplicitLod: result_type(float), result, sampled_image, coord_without_dref, Dref, ImageOperands(Lod)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const dref = try self.emitDrefAndShrunkCoord(inst.ty, coord_id);
                const dref_id = dref.dref_id;
                const shrunk_coord_id = dref.shrunk_coord_id;
                const lod_id = if (resolved.operands.len >= 3) self.operandId(resolved, 2) else return;
                if (resolved.operands.len >= 4) {
                    // textureLodOffset with shadow sampler: sampler, coord, lod, offset → Lod|ConstOffset
                    const offset_id = self.operandId(resolved, 3);
                    try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.ImageSampleDrefExplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(shrunk_coord_id);
                    try self.emitWord(dref_id);
                    try self.emitWord(10); // Image Operand Lod|ConstOffset mask
                    try self.emitWord(lod_id);
                    try self.emitWord(offset_id);
                } else {
                    // Image Operand Lod mask = bit 1 (0x2)
                    try self.emitWord(spirv.encodeInstructionHeader(8, @intFromEnum(spirv.Op.ImageSampleDrefExplicitLod)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(sampled_image_id);
                    try self.emitWord(shrunk_coord_id);
                    try self.emitWord(dref_id);
                    try self.emitWord(2); // Image Operand Lod mask (bit 1)
                    try self.emitWord(lod_id);
                }
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
            .image_gather_offsets => {
                // textureGatherOffsets → OpImageGather with the ConstOffsets
                // image operand (mask bit 0x20), matching glslang -V:
                //   OpImageGather %v4float %si %coord %Component ConstOffsets %arr
                // Fixed IR operand layout from semantic:
                //   [sampled_image, coord, component, offsets_array].
                // The Component operand is ALWAYS present; the ConstOffsets mask
                // word + the constant ivec2[4] array id are appended after it
                // (+2 words over the plain 6-word gather → word count 8).
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const component_id = self.operandId(resolved, 2);
                const offsets_id = self.operandId(resolved, 3);
                try self.emitWord(spirv.encodeInstructionHeader(8, @intFromEnum(spirv.Op.ImageGather)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(coord_id);
                try self.emitWord(component_id);
                try self.emitWord(0x20); // Image Operand mask: ConstOffsets (bit 5)
                try self.emitWord(offsets_id);
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
                } else if (resolved.tag == .image_fetch and resolved.operands.len >= 4) {
                    // texelFetchOffset: [image, coord, lod, offset]
                    const lod_id: u32 = switch (resolved.operands[2]) {
                        .literal_int => |v| try self.emitIntConstant(v),
                        .id => |id| self.constant_alias.get(id) orelse id,
                        else => |o| blk: {
                            std.log.err("codegen.image_fetch: unexpected lod operand kind {s}", .{@tagName(o)});
                            break :blk 0;
                        },
                    };
                    const offset_id = self.operandId(resolved, 3);
                    try self.emitWord(spirv.encodeInstructionHeader(8, @intFromEnum(spirv.Op.ImageFetch)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(10); // Image Operand mask: Lod (bit 1) | ConstOffset (bit 3)
                    try self.emitWord(lod_id);
                    try self.emitWord(offset_id);
                } else if (resolved.tag == .image_fetch and resolved.operands.len > 2) {
                    // texelFetch with lod operand
                    const lod_id = self.operandId(resolved, 2);
                    try self.emitWord(spirv.encodeInstructionHeader(7, @intFromEnum(spirv.Op.ImageFetch)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(image_id);
                    try self.emitWord(coord_id);
                    try self.emitWord(2); // Image Operand mask: Lod (bit 1)
                    try self.emitWord(lod_id);
                } else {
                    try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ImageFetch)));
                    try self.emitWord(result_type_id);
                    try self.emitWord(result_id);
                    try self.emitWord(image_id);
                    try self.emitWord(coord_id);
                }
            },
            .extract_image => {
                // Result type must be the image type inside the sampled image
                // (Sampled=1). One map, keyed by the source sampler ast.Type, is
                // the single source of truth — it holds the exact inner
                // OpTypeImage id emitted by that sampler's ensureType arm. This
                // replaces the old per-type if-else ladder (and its scattered
                // *_inner_id fields), which lumped every int/uint sampler onto
                // one 2D field: int/uint cube/array/3D samplers either referenced
                // an undefined id or collided with a coexisting 2D int sampler
                // (#188). The map keys on the precise type, so distinct
                // Dim/Arrayed/format samplers never alias.
                const result_type_id: u32 = self.sampled_image_inner_by_type.get(std.meta.activeTag(inst.ty)) orelse 0;
                if (result_type_id == 0) return; // No sampler emitted, can't extract
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.OpImage)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
            },
            .sampled_image => {
                // OpSampledImage: combine texture + sampler into a combined image-sampler
                const result_id = resolved.result_id orelse return;
                const texture_id = self.operandId(resolved, 0);
                const sampler_id = self.operandId(resolved, 1);
                // Result type is the combined sampled image type
                const result_type_id = try self.ensureType(inst.ty);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.SampledImage)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(texture_id);
                try self.emitWord(sampler_id);
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
            .image_query_lod => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ImageQueryLod)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(image_id);
                try self.emitWord(coord_id);
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
            .image_box_filter_qcom => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const box_size_id = self.operandId(resolved, 2);
                // OpImageBoxFilterQCOM: result_type result sampled_image coords box_size (wc=6)
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageBoxFilterQCOM)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(coord_id);
                try self.emitWord(box_size_id);
            },
            .image_block_match_sad_qcom => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                // 5 operands: target, target_coords, ref, ref_coords, block_size
                const op_count: u16 = @intCast(3 + resolved.operands.len);
                try self.emitWord(spirv.encodeInstructionHeader(op_count, @intFromEnum(spirv.Op.ImageBlockMatchSADQCOM)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                for (resolved.operands) |op| {
                    try self.emitWord(self.operandValue(op));
                }
            },
            .image_block_match_ssd_qcom => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const op_count: u16 = @intCast(3 + resolved.operands.len);
                try self.emitWord(spirv.encodeInstructionHeader(op_count, @intFromEnum(spirv.Op.ImageBlockMatchSSDQCOM)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                for (resolved.operands) |op| {
                    try self.emitWord(self.operandValue(op));
                }
            },
            .image_sample_weighted_qcom => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const sampled_image_id = self.operandId(resolved, 0);
                const coord_id = self.operandId(resolved, 1);
                const weights_id = self.operandId(resolved, 2);
                // OpImageSampleWeightedQCOM: result_type result sampled_image coords weights (wc=6)
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.ImageSampleWeightedQCOM)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(sampled_image_id);
                try self.emitWord(coord_id);
                try self.emitWord(weights_id);
            },
            .ray_query_initialize => {
                // OpRayQueryInitializeKHR: query accel flags mask origin tmin dir tmax
                const query_id = self.operandId(resolved, 0);
                const accel_id = self.operandId(resolved, 1);
                const flags_id = self.operandId(resolved, 2);
                const mask_id = self.operandId(resolved, 3);
                const origin_id = self.operandId(resolved, 4);
                const tmin_id = self.operandId(resolved, 5);
                const dir_id = self.operandId(resolved, 6);
                const tmax_id = self.operandId(resolved, 7);
                try self.emitWord(spirv.encodeInstructionHeader(9, @intFromEnum(spirv.Op.RayQueryInitializeKHR)));
                try self.emitWord(query_id);
                try self.emitWord(accel_id);
                try self.emitWord(flags_id);
                try self.emitWord(mask_id);
                try self.emitWord(origin_id);
                try self.emitWord(tmin_id);
                try self.emitWord(dir_id);
                try self.emitWord(tmax_id);
            },
            .ray_query_proceed => {
                // OpRayQueryProceedKHR: result_type result query
                const result_type_id = try self.ensureType(.bool);
                const result_id = resolved.result_id orelse return;
                const query_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.RayQueryProceedKHR)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(query_id);
            },
            .ray_query_get_intersection_type => {
                // OpRayQueryGetIntersectionTypeKHR: result_type result query committed
                const result_type_id = try self.ensureType(.uint);
                const result_id = resolved.result_id orelse return;
                const query_id = self.operandId(resolved, 0);
                const committed_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.RayQueryGetIntersectionTypeKHR)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(query_id);
                try self.emitWord(committed_id);
            },
            .ray_query_get_triangle_vertex_positions => {
                // OpRayQueryGetIntersectionTriangleVertexPositionsKHR: result_type result query committed
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const query_id = self.operandId(resolved, 0);
                const committed_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.RayQueryGetIntersectionTriangleVertexPositionsKHR)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(query_id);
                try self.emitWord(committed_id);
            },
            .tensor_query_size_arm => {
                const result_type_id = try self.ensureType(.uint);
                const result_id = resolved.result_id orelse return;
                const tensor_id = self.operandId(resolved, 0);
                const dim_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.TensorQuerySizeARM)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(tensor_id);
                try self.emitWord(dim_id);
            },
            .tensor_read_arm => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const tensor_id = self.operandId(resolved, 0);
                const coords_id = self.operandId(resolved, 1);
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.TensorReadARM)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(tensor_id);
                try self.emitWord(coords_id);
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
            .bit_count => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const val_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.BitCount)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(val_id);
            },
            .bit_reverse => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const val_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.BitReverse)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(val_id);
            },
            .bit_field_insert => {
                // OpBitFieldInsert result_type result_id base insert offset count (wc=7)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const base_id = self.operandId(resolved, 0);
                const insert_id = self.operandId(resolved, 1);
                const offset_id = self.operandId(resolved, 2);
                const count_id = self.operandId(resolved, 3);
                try self.emitWord(spirv.encodeInstructionHeader(7, @intFromEnum(spirv.Op.BitFieldInsert)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(base_id);
                try self.emitWord(insert_id);
                try self.emitWord(offset_id);
                try self.emitWord(count_id);
            },
            .bit_field_s_extract => {
                // OpBitFieldSExtract result_type result_id base offset count (wc=6)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const base_id = self.operandId(resolved, 0);
                const offset_id = self.operandId(resolved, 1);
                const count_id = self.operandId(resolved, 2);
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.BitFieldSExtract)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(base_id);
                try self.emitWord(offset_id);
                try self.emitWord(count_id);
            },
            .bit_field_u_extract => {
                // OpBitFieldUExtract result_type result_id base offset count (wc=6)
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const base_id = self.operandId(resolved, 0);
                const offset_id = self.operandId(resolved, 1);
                const count_id = self.operandId(resolved, 2);
                try self.emitWord(spirv.encodeInstructionHeader(6, @intFromEnum(spirv.Op.BitFieldUExtract)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(base_id);
                try self.emitWord(offset_id);
                try self.emitWord(count_id);
            },
            .derivative => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const val_id = self.operandId(resolved, 1);
                const which = self.operandInt(resolved, 0);
                const opcode: u16 = switch (which) {
                    0 => @intFromEnum(spirv.Op.DPdx),
                    1 => @intFromEnum(spirv.Op.DPdy),
                    2 => @intFromEnum(spirv.Op.DPdxFine),
                    3 => @intFromEnum(spirv.Op.DPdyFine),
                    4 => @intFromEnum(spirv.Op.DPdxCoarse),
                    5 => @intFromEnum(spirv.Op.DPdyCoarse),
                    else => @intFromEnum(spirv.Op.DPdx),
                };
                try self.emitWord(spirv.encodeInstructionHeader(4, opcode));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(val_id);
            },
            .fwidth => {
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                // Check if first operand is literal_int (new format) or id (old format)
                const has_which = resolved.operands.len > 1 and resolved.operands[0] == .literal_int;
                const which: u32 = if (has_which) self.operandInt(resolved, 0) else 0;
                const val_id = if (has_which) self.operandId(resolved, 1) else self.operandId(resolved, 0);
                const opcode: u16 = switch (which) {
                    1 => @intFromEnum(spirv.Op.FwidthFine),
                    2 => @intFromEnum(spirv.Op.FwidthCoarse),
                    else => @intFromEnum(spirv.Op.Fwidth),
                };
                try self.emitWord(spirv.encodeInstructionHeader(4, opcode));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(val_id);
            },
            .return_void => {
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.Return)));
            },
            .kill => {
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.Kill)));
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
                // New basic block: clear AccessChain cache to maintain dominance
                self.access_chain_cache.clearRetainingCapacity();
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
            .switch_inst => {
                // OpSwitch: Selector <Default> [<Case> <Target>]...
                // result_id holds the selector value
                const selector_id = resolved.result_id orelse return;
                const default_id = self.operandId(resolved, 0);
                const wc: u16 = 2 + 1 + @as(u16, @intCast(resolved.operands.len - 1));
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.Switch)));
                try self.emitWord(selector_id);
                try self.emitWord(default_id);
                // Case [literal, target] pairs
                var i: usize = 1;
                while (i < resolved.operands.len) : (i += 2) {
                    try self.emitWord(self.operandValue(resolved.operands[i])); // literal
                    try self.emitWord(self.operandValue(resolved.operands[i + 1])); // target label
                }
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
            .group_non_uniform_elect => {
                // OpGroupNonUniformElect: <result_type> <result_id> <scope>
                // Returns bool: true for one invocation in the group
                const result_type_id = resolved.result_type orelse return;
                const result_id = resolved.result_id orelse return;
                const scope_id = self.operandId(resolved, 0);
                try self.emitWord(spirv.encodeInstructionHeader(4, @intFromEnum(spirv.Op.GroupNonUniformElect)));
                try self.emitWord(result_type_id);
                try self.emitWord(result_id);
                try self.emitWord(scope_id);
            },
            .set_mesh_outputs => {
                // OpSetMeshOutputsEXT <vertex_count> <primitive_count> (no result type)
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.SetMeshOutputsEXT)));
                try self.emitWord(self.operandId(resolved, 0));
                try self.emitWord(self.operandId(resolved, 1));
            },
            .emit_mesh_tasks => {
                // OpEmitMeshTasksEXT <x> <y> <z> [payload]
                const has_payload = inst.operands.len > 3;
                const wc: u16 = if (has_payload) 5 else 4;
                try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.EmitMeshTasksEXT)));
                try self.emitWord(self.operandId(resolved, 0));
                try self.emitWord(self.operandId(resolved, 1));
                try self.emitWord(self.operandId(resolved, 2));
                if (has_payload) try self.emitWord(self.operandId(resolved, 3));
            },
            .report_intersection => {
                // OpReportIntersectionKHR <result_type> <result_id> <hit_t> <hit_kind> → bool
                const bool_type = try self.ensureType(.bool);
                const rid = inst.result_id orelse 0;
                try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.ReportIntersectionKHR)));
                try self.emitWord(bool_type);
                try self.emitWord(rid);
                try self.emitWord(self.operandId(resolved, 0));
                try self.emitWord(self.operandId(resolved, 1));
            },
            .ignore_intersection => {
                // OpIgnoreIntersectionKHR (no operands)
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.IgnoreIntersectionKHR)));
            },
            .terminate_ray => {
                // OpTerminateRayKHR (no operands)
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.TerminateRayKHR)));
            },
            .execute_callable => {
                // OpExecuteCallableKHR <sbt_index> <callable_data>
                try self.emitWord(spirv.encodeInstructionHeader(3, @intFromEnum(spirv.Op.ExecuteCallableKHR)));
                try self.emitWord(self.operandId(resolved, 0));
                try self.emitWord(self.operandId(resolved, 1));
            },
            .trace_ray => {
                // OpTraceRayKHR <accel> <ray_flags> <cull_mask> <sbt_offset> <sbt_stride> <miss_index> <origin> <t_min> <direction> <t_max> <payload>
                try self.emitWord(spirv.encodeInstructionHeader(12, @intFromEnum(spirv.Op.TraceRayKHR)));
                try self.emitWord(self.operandId(resolved, 0));  // acceleration structure
                try self.emitWord(self.operandId(resolved, 1));  // ray flags
                try self.emitWord(self.operandId(resolved, 2));  // cull mask
                try self.emitWord(self.operandId(resolved, 3));  // SBT offset
                try self.emitWord(self.operandId(resolved, 4));  // SBT stride
                try self.emitWord(self.operandId(resolved, 5));  // miss index
                try self.emitWord(self.operandId(resolved, 6));  // origin
                try self.emitWord(self.operandId(resolved, 7));  // tMin
                try self.emitWord(self.operandId(resolved, 8));  // direction
                try self.emitWord(self.operandId(resolved, 9));  // tMax
                try self.emitWord(self.operandId(resolved, 10)); // payload
            },
            .begin_invocation_interlock => {
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.BeginInvocationInterlockEXT)));
            },
            .end_invocation_interlock => {
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.EndInvocationInterlockEXT)));
            },
            .emit_vertex => {
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.EmitVertex)));
            },
            .end_primitive => {
                try self.emitWord(spirv.encodeInstructionHeader(1, @intFromEnum(spirv.Op.EndPrimitive)));
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

    /// Emit floating-point binary op (FAdd, FSub). For matrix types, decomposes
    /// into per-column vector operations since SPIR-V doesn't support matrix arithmetic directly.
    fn emitFloatBinOp(self: *Codegen, op: spirv.Op, inst: ir.Instruction) !void {
        if (!inst.ty.isMatrix()) {
            return self.emitBinOp(op, inst);
        }

        const result_type_id = inst.result_type orelse return;
        const result_id = inst.result_id orelse return;
        const op1 = self.operandId(inst, 0);
        const op2 = self.operandId(inst, 1);

        // Matrix: decompose into per-column vector operations
        const n: u32 = inst.ty.numColumns();
        const col_type = inst.ty.columnType();
        const col_type_id = try self.ensureType(col_type);
        var col_ids: [4]u32 = undefined;
        for (0..n) |i| {
            const ci: u32 = @intCast(i);
            // Extract column from op1
            const c1 = self.allocId();
            try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
            try self.emitWord(col_type_id);
            try self.emitWord(c1);
            try self.emitWord(op1);
            try self.emitWord(ci);
            // Extract column from op2
            const c2 = self.allocId();
            try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(spirv.Op.CompositeExtract)));
            try self.emitWord(col_type_id);
            try self.emitWord(c2);
            try self.emitWord(op2);
            try self.emitWord(ci);
            // Per-column op
            const cr = self.allocId();
            try self.emitWord(spirv.encodeInstructionHeader(5, @intFromEnum(op)));
            try self.emitWord(col_type_id);
            try self.emitWord(cr);
            try self.emitWord(c1);
            try self.emitWord(c2);
            col_ids[i] = cr;
        }
        // Reconstruct matrix: 3 words (header, result_type, result_id) + n columns
        const wc: u16 = 3 + @as(u16, @intCast(n));
        try self.emitWord(spirv.encodeInstructionHeader(wc, @intFromEnum(spirv.Op.CompositeConstruct)));
        try self.emitWord(result_type_id);
        try self.emitWord(result_id);
        for (col_ids[0..n]) |cid| {
            try self.emitWord(cid);
        }
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
            // Caller pre-validates operand kinds; reaching this means semantic
            // analysis emitted the wrong kind. Return 0 (invalid SPIR-V id)
            // so spirv-val catches the malformed module instead of crashing
            // the host process.
            else => |o| blk: {
                std.log.err("codegen.operandId: expected .id at operand[{d}] of {s}; got {s}", .{
                    index, @tagName(inst.tag), @tagName(o),
                });
                break :blk 0;
            },
        };
        return self.constant_alias.get(raw_id) orelse raw_id;
    }

    fn operandInt(self: *Codegen, inst: ir.Instruction, index: usize) u32 {
        _ = self;
        return switch (inst.operands[index]) {
            .literal_int => |v| v,
            else => |o| blk: {
                std.log.err("codegen.operandInt: expected .literal_int at operand[{d}] of {s}; got {s}", .{
                    index, @tagName(inst.tag), @tagName(o),
                });
                break :blk 0;
            },
        };
    }

    fn operandValue(self: *Codegen, op: ir.Instruction.Operand) u32 {
        return switch (op) {
            .id => |v| self.constant_alias.get(v) orelse v,
            .literal_int => |v| v,
            .literal_float => |v| @as(u32, @bitCast(v)),
            .literal_string => 0,
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

    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false, .std140);
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

    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false, .std140);
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
    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false, .std140);
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
    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false, .std140);
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
    // The loop must have an observable effect (write to output) so DCE/deadLoopElim
    // doesn't remove it. A bare `float x = 1.0;` is dead code.
    const source =
        \\#version 430
        \\layout(location = 0) out vec4 _fragColor;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i = i + 1) { sum = sum + 1.0; }
        \\    _fragColor = vec4(sum);
        \\}
    ;
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var pp = preprocessor.Preprocessor.init(alloc);
    defer pp.deinit();
    const pp_tokens = pp.process(source, tokens) catch tokens;
    defer if (pp_tokens.ptr != tokens.ptr) alloc.free(pp_tokens);
    var root = try parser.parse(alloc, source, pp_tokens);
    defer parser.freeTree(alloc, &root);
    var module = semantic.analyze(alloc, &root) catch |err| {
        if (err == error.TypeMismatch) return;
        return err;
    };
    defer module.deinit();
    const result = try generate(alloc, &module, .fragment, .@"1.5", 450, false, .std140);
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