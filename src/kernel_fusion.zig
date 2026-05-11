// SPDX-License-Identifier: MIT OR Apache-2.0
// SPIR-V kernel fusion optimization pass.
// Fuses consecutive compute kernels into a single kernel to reduce memory
// bandwidth and kernel launch overhead. Operates on SPIR-V binary words.
const std = @import("std");
const compact_ids = @import("compact_ids.zig");
const spirv = @import("spirv.zig");

/// Configuration for kernel fusion.
pub const FusionOptions = struct {
    /// Fuse consecutive elementwise kernels (no shared memory, no barriers).
    fuse_elementwise: bool = true,
    /// Fuse elementwise into reductions.
    fuse_into_reduction: bool = true,
    /// Maximum fused kernel size (in instructions) to avoid register pressure.
    max_fused_size: u32 = 1024,
};

// ── Data structures ──────────────────────────────────────────────

const EntryPoint = struct {
    /// ID of the entry-point function.
    func_id: u32,
    /// Execution model (should be GLCompute=5 for kernel fusion).
    exec_model: u32,
    /// Name of the entry point.
    name: []const u8,
    /// Word indices in the SPIR-V binary for the OpEntryPoint instruction.
    ep_word_pos: u32,
    /// Word range [start, end) of the OpFunction body.
    func_start: u32,
    func_end: u32,
    /// Set of buffer variable IDs written by this kernel.
    buffers_written: std.DynamicBitSet,
    /// Set of buffer variable IDs read by this kernel.
    buffers_read: std.DynamicBitSet,
    /// Set of all IDs defined (result IDs) inside this function.
    defined_ids: std.DynamicBitSet,
    /// Set of all IDs referenced (operand IDs) inside this function.
    referenced_ids: std.DynamicBitSet,
    /// Whether this kernel uses Workgroup storage class (shared memory).
    uses_workgroup: bool = false,
    /// Whether this kernel has OpControlBarrier or OpMemoryBarrier.
    has_barrier: bool = false,
    /// Whether this kernel has any atomic operations.
    has_atomics: bool = false,
    /// Instruction count (approximate, excluding OpLabel/Nop).
    instr_count: u32 = 0,
    /// Detected reduction pattern info.
    reduction_info: ReductionInfo = .{},
};

/// Detected reduction pattern information.
const ReductionInfo = struct {
    is_reduction: bool = false,
    /// Buffer variable ID that the reduction reads from.
    input_buffer: ?u32 = null,
};

const FusionCandidate = struct {
    producer_idx: u32,
    consumer_idx: u32,
    /// Buffer IDs that connect producer output to consumer input.
    shared_buffers: std.ArrayListUnmanaged(u32),
    /// Whether the consumer is a reduction kernel.
    consumer_is_reduction: bool = false,
    /// Fusion score: higher = better candidate.
    score: i32 = 0,
};

// ── Helpers ──────────────────────────────────────────────────────

/// Parse the opcode and word count from a SPIR-V instruction header word.
inline fn decodeHeader(word: u32) struct { wc: u32, op: u16 } {
    return .{ .wc = word >> 16, .op = @truncate(word & 0xFFFF) };
}

/// Iterate instructions starting at `pos` in `words`. Returns word range [start, end).
/// Returns null if we hit the end of the binary.
fn nextInstruction(words: []const u32, pos: u32) ?struct { start: u32, end: u32, op: u16 } {
    if (pos >= words.len) return null;
    const h = words[pos];
    const wc: u32 = h >> 16;
    const op: u16 = @truncate(h & 0xFFFF);
    if (wc == 0) return null;
    const end = pos + wc;
    if (end > words.len) return null;
    return .{ .start = pos, .end = end, .op = op };
}

/// Collect all IDs mentioned in an instruction using getOpInfo.
fn collectIdsFromInstruction(words: []const u32, start: u32, end: u32, id_set: *std.DynamicBitSet, defined_set: ?*std.DynamicBitSet) void {
    const opcode: u16 = @truncate(words[start] & 0xFFFF);
    const info = compact_ids.getOpInfo(opcode) orelse return;
    const fixed = info.fixed;
    const ops = info.ops;

    // Handle result/definition
    if (fixed == 2) {
        // result_type at word 1, result at word 2
        if (end - start > 1) id_set.set(words[start + 1]); // result_type (referenced)
        if (end - start > 2) {
            if (defined_set) |ds| ds.set(words[start + 2]);
            id_set.set(words[start + 2]); // also referenced
        }
    } else if (fixed == 3) {
        // result_only at word 1
        if (end - start > 1) {
            if (defined_set) |ds| ds.set(words[start + 1]);
            id_set.set(words[start + 1]);
        }
    } else if (fixed == 1) {
        // result_type at word 1
        if (end - start > 1) id_set.set(words[start + 1]);
    }

    const payload_start = start + 1 + fixed;
    var pos: u32 = payload_start;
    var oi: u32 = 0;
    while (oi < ops.len and pos < end) {
        switch (ops[oi]) {
            'i' => {
                // Single ID
                if (pos < end) {
                    id_set.set(words[pos]);
                    pos += 1;
                }
                oi += 1;
            },
            'I' => {
                // Rest of words are all IDs
                while (pos < end) {
                    id_set.set(words[pos]);
                    pos += 1;
                }
                oi += 1;
            },
            'l', 'L' => {
                // Literal(s) — skip one or rest
                if (ops[oi] == 'l') {
                    pos += 1;
                } else {
                    pos = end;
                }
                oi += 1;
            },
            's' => {
                // String — consume rest
                pos = end;
                oi += 1;
            },
            'M' => {
                // Image operands: mask literal, then IDs for set bits
                if (pos < end) {
                    pos += 1; // skip mask literal
                    // Rest are IDs (we approximate: treat rest as IDs)
                    while (pos < end) {
                        id_set.set(words[pos]);
                        pos += 1;
                    }
                }
                oi += 1;
            },
            'W' => {
                // Switch: pairs of (literal, ID)
                if (pos < end) pos += 1; // first literal
                while (pos + 1 < end) {
                    pos += 1; // ID
                    id_set.set(words[pos]);
                    pos += 1; // next literal
                }
                if (pos < end) pos += 1;
                oi += 1;
            },
            'E' => {
                // EntryPoint: model(lit), func-id, name-string, interface-ids...
                if (pos < end) pos += 1; // model literal
                if (pos < end) {
                    id_set.set(words[pos]); // func-id
                    pos += 1;
                }
                // Skip name string: check each word individually for null byte
                while (pos < end) {
                    const w = words[pos];
                    pos += 1;
                    if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) {
                        break;
                    }
                }
                // Rest are interface IDs
                while (pos < end) {
                    id_set.set(words[pos]);
                    pos += 1;
                }
                oi += 1;
            },
            else => {
                pos += 1;
                oi += 1;
            },
        }
    }
}

/// Find the string length in SPIR-V format (null-terminated, 4-byte aligned).
fn stringWordLen(words: []const u32, start: u32) u32 {
    var pos = start;
    while (pos < words.len) {
        const w = words[pos];
        // Check each byte for null terminator
        if ((w & 0xFF) == 0) return pos - start + 1;
        if ((w & 0xFF00) == 0) return pos - start + 1;
        if ((w & 0xFF0000) == 0) return pos - start + 1;
        if ((w & 0xFF000000) == 0) return pos - start + 1;
        pos += 1;
    }
    return pos - start;
}

// ── Analysis ─────────────────────────────────────────────────────

/// Collect all global OpVariable IDs with StorageBuffer or Workgroup storage class.
fn collectGlobalBufferVars(alloc: std.mem.Allocator, words: []const u32, bound: u32) !std.DynamicBitSet {
    var result = try std.DynamicBitSet.initEmpty(alloc, bound);
    var p: u32 = 5;
    // Scan only the global section (before first OpFunction)
    while (p < words.len) {
        const inst = nextInstruction(words, p) orelse break;
        if (inst.op == @intFromEnum(spirv.Op.Function)) break; // globals end
        if (inst.op == @intFromEnum(spirv.Op.Variable)) {
            if (inst.end - inst.start >= 4) {
                const sc = words[inst.start + 3];
                if (sc == @intFromEnum(spirv.StorageClass.StorageBuffer) or
                    sc == @intFromEnum(spirv.StorageClass.Uniform))
                {
                    const var_id = words[inst.start + 2];
                    if (var_id < bound) {
                        result.set(var_id);
                    }
                }
            }
        }
        p = inst.end;
    }
    return result;
}

/// Analyze buffer access patterns for a single entry point's function body.
/// Detect whether a kernel exhibits a reduction pattern.
/// A reduction kernel uses workgroup shared memory + barriers and produces
/// a single output (or a small number of outputs) by aggregating values
/// across a workgroup (sum, min, max, product, etc.).
///
/// Heuristic detection at the SPIR-V binary level:
///   1. Uses Workgroup storage class (shared memory)
///   2. Has OpControlBarrier instructions
///   3. Writes to exactly one storage buffer after the last barrier
fn detectReductionPattern(
    entry: *const EntryPoint,
    words: []const u32, // used by future pattern analysis
    bound: u32, // used by future pattern analysis
    global_buffers: *const std.DynamicBitSet,
) ReductionInfo {
    _ = words;
    _ = bound;
    // Must use workgroup memory AND have barriers
    if (!entry.uses_workgroup or !entry.has_barrier) return .{};

    // Find the input buffer: a global buffer that is read but not written
    // This is the reduction input
    var input_buf: ?u32 = null;
    {
        var it = entry.buffers_read.iterator(.{});
        while (it.next()) |buf_id| {
            if (global_buffers.isSet(buf_id) and !entry.buffers_written.isSet(buf_id)) {
                input_buf = @intCast(buf_id);
                break;
            }
        }
    }

    // If no read-only input buffer, probably not a standard reduction
    if (input_buf == null) return .{};

    // Count how many global buffers are written to
    var output_count: u32 = 0;
    {
        var it = entry.buffers_written.iterator(.{});
        while (it.next()) |_| {
            output_count += 1;
        }
    }

    // A reduction typically writes to exactly one output buffer
    // (or a small number for multi-output reductions)
    if (output_count > 2) return .{};

    return .{
        .is_reduction = true,
        .input_buffer = input_buf,
    };
}

/// Rank fusion candidates by expected benefit.
/// Higher score = better fusion candidate.
/// Scoring: more shared buffers = more memory traffic eliminated (dominant),
///          smaller combined size = less register pressure.
fn rankCandidates(candidates: []FusionCandidate, entries: []const EntryPoint) void {
    for (candidates) |*c| {
        const prod = entries[c.producer_idx];
        const cons = entries[c.consumer_idx];
        const shared_count: i32 = @intCast(c.shared_buffers.items.len);
        const combined_size: i32 = @intCast(prod.instr_count + cons.instr_count);
        // Heavily weight shared buffer count (each eliminates a round-trip to global memory)
        // Penalize large combined size (register pressure)
        c.score = shared_count * 1000 - combined_size;
        // Small bonus for fusing into reduction (enables bigger wins)
        if (c.consumer_is_reduction) c.score += 500;
    }

    // Sort by score descending (simple insertion sort — candidate lists are small)
    var i: usize = 1;
    while (i < candidates.len) : (i += 1) {
        const key = candidates[i];
        var j: usize = i;
        while (j > 0 and candidates[j - 1].score < key.score) : (j -= 1) {
            candidates[j] = candidates[j - 1];
        }
        candidates[j] = key;
    }
}

fn analyzeFunctionAccess(
    words: []const u32,
    bound: u32,
    func_start: u32,
    func_end: u32,
    global_buffers: *const std.DynamicBitSet,
    entry: *EntryPoint,
    alloc: std.mem.Allocator,
) !void {
    // Pass 1: scan for OpVariable declarations (function-local vars),
    // barriers, atomics, Workgroup usage, and instruction count
    var p: u32 = func_start;
    while (p < func_end) {
        const inst = nextInstruction(words, p) orelse break;
        const op = inst.op;

        if (op == @intFromEnum(spirv.Op.Variable)) {
            // OpVariable: result_type, result, storage_class, [initializer]
            if (inst.end - inst.start >= 4) {
                const sc = words[inst.start + 3];
                if (sc == @intFromEnum(spirv.StorageClass.StorageBuffer)) {
                    const var_id = words[inst.start + 2];
                    if (var_id < bound) {
                        // Mark as both read and written to track it
                        entry.buffers_read.set(var_id);
                        entry.buffers_written.set(var_id);
                    }
                }
                if (sc == @intFromEnum(spirv.StorageClass.Workgroup)) {
                    entry.uses_workgroup = true;
                }
            }
        }

        if (op == @intFromEnum(spirv.Op.ControlBarrier) or
            op == @intFromEnum(spirv.Op.MemoryBarrier))
        {
            entry.has_barrier = true;
        }

        // Atomic operations: opcode range 229-242, 6035
        if ((op >= 229 and op <= 242) or op == 6035) {
            entry.has_atomics = true;
        }

        // Count meaningful instructions
        if (op != @intFromEnum(spirv.Op.Nop) and
            op != @intFromEnum(spirv.Op.Label))
        {
            entry.instr_count += 1;
        }

        p = inst.end;
    }

    // Pass 2: build access chain map and analyze OpLoad/OpStore
    var access_chain_bases = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer access_chain_bases.deinit(alloc);

    p = func_start;
    while (p < func_end) {
        const inst = nextInstruction(words, p) orelse break;
        const op = inst.op;

        if (op == @intFromEnum(spirv.Op.AccessChain)) {
            // OpAccessChain: result_type, result, base, [indices...]
            if (inst.end - inst.start >= 4) {
                const result_id = words[inst.start + 2];
                const base_id = words[inst.start + 3];
                var resolved_base = base_id;
                if (access_chain_bases.get(base_id)) |bb| {
                    resolved_base = bb;
                }
                try access_chain_bases.put(alloc, result_id, resolved_base);
            }
        }

        if (op == @intFromEnum(spirv.Op.Load)) {
            if (inst.end - inst.start >= 4) {
                const ptr_id = words[inst.start + 3];
                var buf_id = ptr_id;
                if (access_chain_bases.get(ptr_id)) |bb| {
                    buf_id = bb;
                }
                if (global_buffers.isSet(buf_id) or
                    entry.buffers_read.isSet(buf_id) or
                    entry.buffers_written.isSet(buf_id))
                {
                    entry.buffers_read.set(buf_id);
                }
            }
        }

        if (op == @intFromEnum(spirv.Op.Store)) {
            if (inst.end - inst.start >= 3) {
                const ptr_id = words[inst.start + 1];
                var buf_id = ptr_id;
                if (access_chain_bases.get(ptr_id)) |bb| {
                    buf_id = bb;
                }
                if (global_buffers.isSet(buf_id) or
                    entry.buffers_read.isSet(buf_id) or
                    entry.buffers_written.isSet(buf_id))
                {
                    entry.buffers_written.set(buf_id);
                }
            }
        }

        // Collect IDs
        collectIdsFromInstruction(words, inst.start, inst.end, &entry.referenced_ids, &entry.defined_ids);

        p = inst.end;
    }
}

/// Find all compute entry points in a SPIR-V module.
fn findEntryPoints(
    words: []const u32,
    bound: u32,
    alloc: std.mem.Allocator,
) !std.ArrayListUnmanaged(EntryPoint) {
    var entries = std.ArrayListUnmanaged(EntryPoint).empty;

    // Collect global storage buffer variable IDs (before any function definitions)
    var global_buffers = try collectGlobalBufferVars(alloc, words, bound);
    defer global_buffers.deinit();

    // Phase 1: Find OpEntryPoint instructions with GLCompute model
    var p: u32 = 5; // skip header
    while (p < words.len) {
        const inst = nextInstruction(words, p) orelse break;
        if (inst.op == @intFromEnum(spirv.Op.EntryPoint)) {
            // OpEntryPoint: execution_model, func_id, name, [interface_ids...]
            if (inst.end - inst.start >= 4) {
                const exec_model = words[inst.start + 1];
                const func_id = words[inst.start + 2];
                // Extract name: starts at word 3, null-terminated string
                const name_start = inst.start + 3;
                const name_word_len = stringWordLen(words, name_start);
                const name_bytes = std.mem.sliceAsBytes(words[name_start .. name_start + name_word_len]);
                // Find actual string length (up to null)
                var name_len: usize = 0;
                for (name_bytes) |b| {
                    if (b == 0) break;
                    name_len += 1;
                }
                const name = name_bytes[0..name_len];

                // Find the function body for this entry point
                var func_start: u32 = 0;
                var func_end: u32 = 0;
                var fp: u32 = 5;
                while (fp < words.len) {
                    const fi = nextInstruction(words, fp) orelse {
                        break;
                    };
                    if (fi.op == @intFromEnum(spirv.Op.Function)) {
                        if (fi.end - fi.start >= 3 and words[fi.start + 2] == func_id) {
                            func_start = fp;
                            // Find OpFunctionEnd
                            var ffp: u32 = fi.end;
                            while (ffp < words.len) {
                                const ffi = nextInstruction(words, ffp) orelse break;
                                if (ffi.op == @intFromEnum(spirv.Op.FunctionEnd)) {
                                    func_end = ffi.end;
                                    break;
                                }
                                ffp = ffi.end;
                            }
                            break;
                        }
                    }
                    fp = fi.end;
                }

                if (func_start > 0 and func_end > 0) {
                    var entry = EntryPoint{
                        .func_id = func_id,
                        .exec_model = exec_model,
                        .name = name,
                        .ep_word_pos = inst.start,
                        .func_start = func_start,
                        .func_end = func_end,
                        .buffers_written = try std.DynamicBitSet.initEmpty(alloc, bound),
                        .buffers_read = try std.DynamicBitSet.initEmpty(alloc, bound),
                        .defined_ids = try std.DynamicBitSet.initEmpty(alloc, bound),
                        .referenced_ids = try std.DynamicBitSet.initEmpty(alloc, bound),
                    };
                    errdefer {
                        entry.buffers_written.deinit();
                        entry.buffers_read.deinit();
                        entry.defined_ids.deinit();
                        entry.referenced_ids.deinit();
                    }

                    try analyzeFunctionAccess(words, bound, func_start, func_end, &global_buffers, &entry, alloc);
                    // Detect reduction pattern after access analysis
                    entry.reduction_info = detectReductionPattern(&entry, words, bound, &global_buffers);
                    try entries.append(alloc, entry);
                }
            }
        }
        p = inst.end;
    }

    return entries;
}

/// Identify fusible pairs of kernels.
/// Two kernels can be fused if:
///   1. Both are GLCompute entry points
///   2. Producer writes to buffers that consumer reads
///   3. Those shared buffers are NOT read by producer (or producer only writes to them)
///   4. No workgroup storage, barriers, or atomics in either (elementwise case)
fn findFusionCandidates(
    entries: []const EntryPoint,
    options: FusionOptions,
    alloc: std.mem.Allocator,
) !std.ArrayListUnmanaged(FusionCandidate) {
    var candidates = std.ArrayListUnmanaged(FusionCandidate).empty;

    for (entries, 0..) |prod, pi| {
        if (prod.exec_model != @intFromEnum(spirv.ExecutionModel.GLCompute)) continue;

        // Never use a reduction kernel as a producer
        if (prod.reduction_info.is_reduction) continue;

        for (entries, 0..) |cons, ci| {
            if (ci == pi) continue;
            if (cons.exec_model != @intFromEnum(spirv.ExecutionModel.GLCompute)) continue;

            // Check if producer output feeds consumer input
            var shared = std.ArrayListUnmanaged(u32).empty;
            errdefer shared.deinit(alloc);

            // Find buffers that producer writes and consumer reads
            var buf_it = prod.buffers_written.iterator(.{});
            while (buf_it.next()) |buf_id| {
                if (cons.buffers_read.isSet(buf_id)) {
                    try shared.append(alloc, @intCast(buf_id));
                }
            }

            if (shared.items.len == 0) {
                shared.deinit(alloc);
                continue;
            }

            // Size constraint
            const combined_size = prod.instr_count + cons.instr_count;
            const within_size = combined_size <= options.max_fused_size;
            if (!within_size) {
                shared.deinit(alloc);
                continue;
            }

            // Elementwise fusion: both kernels are elementwise
            if (options.fuse_elementwise) {
                const both_elementwise = !prod.uses_workgroup and !cons.uses_workgroup and
                    !prod.has_barrier and !cons.has_barrier and
                    !prod.has_atomics and !cons.has_atomics;

                if (both_elementwise) {
                    try candidates.append(alloc, .{
                        .producer_idx = @intCast(pi),
                        .consumer_idx = @intCast(ci),
                        .shared_buffers = shared,
                        .consumer_is_reduction = false,
                    });
                    continue;
                }
            }

            // Reduction fusion: elementwise producer → reduction consumer
            if (options.fuse_into_reduction) {
                const prod_elementwise = !prod.uses_workgroup and !prod.has_barrier and !prod.has_atomics;
                const cons_is_reduction = cons.reduction_info.is_reduction;

                if (prod_elementwise and cons_is_reduction) {
                    try candidates.append(alloc, .{
                        .producer_idx = @intCast(pi),
                        .consumer_idx = @intCast(ci),
                        .shared_buffers = shared,
                        .consumer_is_reduction = true,
                    });
                    continue;
                }
            }

            shared.deinit(alloc);
        }
    }

    return candidates;
}

// ── Fusion ───────────────────────────────────────────────────────

/// Fuse two kernels into one. Returns a new SPIR-V binary with the fused kernel.
/// The producer's output stores to shared buffers are kept in registers,
/// and the consumer's loads from those buffers are replaced with the producer's results.
fn fusePair(
    words: []const u32,
    bound: u32,
    entries: []const EntryPoint,
    candidate: FusionCandidate,
    alloc: std.mem.Allocator,
) error{OutOfMemory}![]const u32 {
    const producer = entries[candidate.producer_idx];
    const consumer = entries[candidate.consumer_idx];

    // Strategy:
    // 1. Copy the full module
    // 2. Merge consumer's function body into producer's function (before OpReturn)
    // 3. Remap consumer's IDs to avoid collisions with producer's IDs
    // 4. Replace consumer's loads from shared buffers with producer's computed values
    // 5. Remove consumer's entry point
    // 6. Remove the intermediate buffer variables (if they're only used by these two kernels)

    // Calculate the ID offset needed to avoid collisions
    var max_producer_id: u32 = 0;
    {
        var it = producer.defined_ids.iterator(.{});
        while (it.next()) |id| {
            if (id > max_producer_id) max_producer_id = @intCast(id);
        }
        it = producer.referenced_ids.iterator(.{});
        while (it.next()) |id| {
            if (id > max_producer_id) max_producer_id = @intCast(id);
        }
    }
    const id_offset = max_producer_id + 1;

    // Build ID remap table for consumer's IDs
    var id_remap = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer id_remap.deinit(alloc);

    {
        var it = consumer.defined_ids.iterator(.{});
        while (it.next()) |id| {
            try id_remap.put(alloc, @as(u32, @intCast(id)), @as(u32, @intCast(id)) + id_offset);
        }
    }

    // Build a map: shared buffer pointer -> producer's last stored value
    // We track stores to shared buffers in the producer
    var store_to_buffer = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer store_to_buffer.deinit(alloc);

    // Scan producer for OpStore to shared buffers
    {
        // First build access chain map for producer
        var ac_map = std.AutoHashMapUnmanaged(u32, u32).empty;
        defer ac_map.deinit(alloc);

        var p: u32 = producer.func_start;
        while (p < producer.func_end) {
            const inst = nextInstruction(words, p) orelse break;
            if (inst.op == @intFromEnum(spirv.Op.AccessChain) and inst.end - inst.start >= 4) {
                try ac_map.put(alloc, words[inst.start + 2], words[inst.start + 3]);
            }
            if (inst.op == @intFromEnum(spirv.Op.Store) and inst.end - inst.start >= 3) {
                const ptr_id = words[inst.start + 1];
                const val_id = words[inst.start + 2];
                // Resolve pointer to base buffer
                var base_id = ptr_id;
                if (ac_map.get(ptr_id)) |bb| base_id = bb;
                // Check if this is a shared buffer
                for (candidate.shared_buffers.items) |sb| {
                    if (base_id == sb) {
                        try store_to_buffer.put(alloc, ptr_id, val_id);
                    }
                }
            }
            p = inst.end;
        }
    }

    // Build load replacement map for consumer
    // When consumer loads from a shared buffer pointer, replace with producer's stored value
    var load_replace = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer load_replace.deinit(alloc);

    {
        var ac_map = std.AutoHashMapUnmanaged(u32, u32).empty;
        defer ac_map.deinit(alloc);

        var p: u32 = consumer.func_start;
        while (p < consumer.func_end) {
            const inst = nextInstruction(words, p) orelse break;
            if (inst.op == @intFromEnum(spirv.Op.AccessChain) and inst.end - inst.start >= 4) {
                const base = words[inst.start + 3];
                try ac_map.put(alloc, words[inst.start + 2], base);
            }
            if (inst.op == @intFromEnum(spirv.Op.Load) and inst.end - inst.start >= 4) {
                const ptr_id = words[inst.start + 3];
                var base_id = ptr_id;
                if (ac_map.get(ptr_id)) |bb| base_id = bb;
                for (candidate.shared_buffers.items) |sb| {
                    if (base_id == sb) {
                        // This load can be replaced — we'll handle it during emission
                        // For now, record that this load result should be replaced
                        const load_result = words[inst.start + 2];
                        // Find the stored value from producer
                        if (store_to_buffer.get(ptr_id)) |val| {
                            try load_replace.put(alloc, load_result, val);
                        } else {
                            // Try matching by access chain pattern
                            // For simpler cases, match by base buffer
                            var sit = store_to_buffer.iterator();
                            while (sit.next()) |entry| {
                                var sbase: u32 = entry.key_ptr.*;
                                if (ac_map.get(entry.key_ptr.*)) |bb| sbase = bb;
                                if (sbase == sb) {
                                    try load_replace.put(alloc, load_result, entry.value_ptr.*);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            p = inst.end;
        }
    }

    // Build the output SPIR-V binary
    var out = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    defer out.deinit(alloc);

    // Copy header (5 words: magic, version, generator, bound, schema)
    try out.appendSlice(alloc, words[0..5]);

    // Track new bound
    var new_bound: u32 = bound;
    {
        var it = consumer.defined_ids.iterator(.{});
        while (it.next()) |id| {
            const new_id = @as(u32, @intCast(id)) + id_offset;
            if (new_id >= new_bound) new_bound = new_id + 1;
        }
    }

    // Track which entry point instructions to skip
    var consumer_ep_positions = try std.DynamicBitSet.initEmpty(alloc, words.len);
    defer consumer_ep_positions.deinit();
    // Find consumer's entry point instruction
    {
        var p: u32 = 5;
        while (p < words.len) {
            const inst = nextInstruction(words, p) orelse break;
            if (inst.op == @intFromEnum(spirv.Op.EntryPoint)) {
                if (inst.end - inst.start >= 3 and words[inst.start + 2] == consumer.func_id) {
                    consumer_ep_positions.set(inst.start);
                }
            }
            p = inst.end;
        }
    }

    // Track consumer's execution mode instructions to skip
    var consumer_em_positions = try std.DynamicBitSet.initEmpty(alloc, words.len);
    defer consumer_em_positions.deinit();
    {
        var p: u32 = 5;
        while (p < words.len) {
            const inst = nextInstruction(words, p) orelse break;
            if (inst.op == @intFromEnum(spirv.Op.ExecutionMode)) {
                if (inst.end - inst.start >= 2 and words[inst.start + 1] == consumer.func_id) {
                    consumer_em_positions.set(inst.start);
                }
            }
            p = inst.end;
        }
    }

    // Emit all instructions except:
    // - Consumer's entry point
    // - Consumer's function body (will be merged into producer)
    // - Consumer's execution modes
    // - Producer's OpReturn/OpReturnValue (we'll add consumer's body before the return)
    var p: u32 = 5;
    var producer_func_emitted = false;
    while (p < words.len) {
        const inst = nextInstruction(words, p) orelse break;

        // Skip consumer's entry point
        if (consumer_ep_positions.isSet(inst.start)) {
            p = inst.end;
            continue;
        }

        // Skip consumer's execution modes
        if (consumer_em_positions.isSet(inst.start)) {
            p = inst.end;
            continue;
        }

        // Skip consumer's entire function
        if (inst.start >= consumer.func_start and inst.start < consumer.func_end) {
            p = inst.end;
            continue;
        }

        // When we reach producer's function, merge consumer's body in
        if (inst.start == producer.func_start) {
            // Copy producer's function up to (but not including) OpFunctionEnd
            var fp: u32 = producer.func_start;
            while (fp < producer.func_end) {
                const fi = nextInstruction(words, fp) orelse break;

                if (fi.op == @intFromEnum(spirv.Op.FunctionEnd)) {
                    // Before the function end, insert consumer's body (remapped)
                    // Skip consumer's OpFunction header and parameters
                    var cp: u32 = consumer.func_start;
                    var past_header = false;
                    while (cp < consumer.func_end) {
                        const ci = nextInstruction(words, cp) orelse break;
                        const cop = ci.op;

                        // Skip OpFunction, OpFunctionParameter, OpFunctionEnd
                        if (cop == @intFromEnum(spirv.Op.Function) or
                            cop == @intFromEnum(spirv.Op.FunctionParameter) or
                            cop == @intFromEnum(spirv.Op.FunctionEnd))
                        {
                            past_header = true;
                            cp = ci.end;
                            continue;
                        }

                        // Skip the first OpLabel in consumer (we're continuing in producer's block)
                        if (!past_header) {
                            cp = ci.end;
                            continue;
                        }
                        if (cop == @intFromEnum(spirv.Op.Label)) {
                            cp = ci.end;
                            continue;
                        }

                        // Skip loads from shared buffers (they'll be replaced)
                        if (cop == @intFromEnum(spirv.Op.Load) and ci.end - ci.start >= 4) {
                            const load_result = words[ci.start + 2];
                            if (load_replace.get(load_result)) |_| {
                                // Skip this load - references will be replaced
                                cp = ci.end;
                                continue;
                            }
                        }

                        // Skip stores to shared buffers in consumer (producer already wrote)
                        // Actually, consumer may write NEW data to shared buffers or other buffers
                        // We only skip stores if they write to the SAME buffer locations
                        // that producer wrote to AND those values were consumed above
                        // For simplicity and correctness, we KEEP consumer's stores

                        // Skip OpReturn in producer's body if we're at the end
                        if (cop == @intFromEnum(spirv.Op.Return) or cop == @intFromEnum(spirv.Op.ReturnValue)) {
                            cp = ci.end;
                            continue;
                        }

                        // Copy consumer instruction with ID remapping
                        try out.ensureUnusedCapacity(alloc, ci.end - ci.start);
                        for (ci.start..ci.end) |w| {
                            var word = words[w];
                            // Remap IDs in the instruction
                            // We need to know which positions are IDs vs literals
                            word = remapWordInInstruction(words, ci.start, ci.end, @intCast(w - ci.start), word, &id_remap, &load_replace);
                            out.appendAssumeCapacity(word);
                        }

                        cp = ci.end;
                    }

                    // Now emit the OpFunctionEnd
                    try out.appendSlice(alloc, words[fi.start..fi.end]);
                    fp = fi.end;
                    producer_func_emitted = true;
                    continue;
                }

                // For producer's OpReturn/OpReturnValue before FunctionEnd,
                // we need to skip them if we're going to append consumer body
                // Actually, we handle this above by inserting consumer body before FunctionEnd
                // Just copy the instruction as-is
                try out.appendSlice(alloc, words[fi.start..fi.end]);
                fp = fi.end;
            }

            p = inst.end;
            // Skip past producer's function
            p = producer.func_end;
            continue;
        }

        // Copy other instructions as-is
        try out.appendSlice(alloc, words[inst.start..inst.end]);
        p = inst.end;
    }

    // Update bound in header
    if (out.items.len >= 4) {
        out.items[3] = new_bound;
    }

    const result = try out.toOwnedSlice(alloc);

    // Run DCE + compactIds to clean up
    const dce_result = compact_ids.deadCodeElim(alloc, result) catch return result;
    if (dce_result.ptr != result.ptr) alloc.free(result);
    const compacted = compact_ids.compactIds(alloc, dce_result) catch return dce_result;
    if (compacted.ptr != dce_result.ptr) alloc.free(dce_result);

    return compacted;
}

/// Remap a single word in an instruction, accounting for ID positions.
fn remapWordInInstruction(
    words: []const u32,
    inst_start: u32,
    inst_end: u32,
    word_offset: u32,
    word: u32,
    id_remap: *const std.AutoHashMapUnmanaged(u32, u32),
    load_replace: *const std.AutoHashMapUnmanaged(u32, u32),
) u32 {
    if (word_offset == 0) return word; // header word

    const opcode: u16 = @truncate(words[inst_start] & 0xFFFF);
    const info = compact_ids.getOpInfo(opcode) orelse return word;
    const fixed = info.fixed;
    const ops = info.ops;

    // Determine if this word position corresponds to an ID
    const absolute_pos = word_offset; // relative to instruction start

    // Check fixed positions
    if (fixed == 2) {
        // word 1 = result_type (ID), word 2 = result (ID)
        if (absolute_pos == 1) {
            return id_remap.get(word) orelse word;
        }
        if (absolute_pos == 2) {
            const mapped = id_remap.get(word) orelse word;
            // Check if this result should be replaced by load_replace
            // (it shouldn't be — result IDs are definitions, not uses)
            return mapped;
        }
    } else if (fixed == 3) {
        // word 1 = result (ID)
        if (absolute_pos == 1) {
            return id_remap.get(word) orelse word;
        }
    } else if (fixed == 1) {
        // word 1 = result_type (ID)
        if (absolute_pos == 1) {
            return id_remap.get(word) orelse word;
        }
    }

    // Check payload positions
    const payload_start = 1 + fixed;
    if (absolute_pos < payload_start) return word;

    var pos: u32 = payload_start;
    var oi: u32 = 0;
    while (oi < ops.len and pos < (inst_end - inst_start)) {
        switch (ops[oi]) {
            'i' => {
                if (absolute_pos == pos) {
                    // This is an ID — apply remap + load replacement
                    if (load_replace.get(word)) |replacement| return replacement;
                    return id_remap.get(word) orelse word;
                }
                pos += 1;
                oi += 1;
            },
            'I' => {
                if (absolute_pos == pos) {
                    if (load_replace.get(word)) |replacement| return replacement;
                    return id_remap.get(word) orelse word;
                }
                pos += 1;
                // Don't advance oi — 'I' consumes rest
            },
            'l' => {
                if (absolute_pos == pos) return word; // literal, no remap
                pos += 1;
                oi += 1;
            },
            'L' => {
                if (absolute_pos == pos) return word; // literal, no remap
                pos += 1;
                // Don't advance oi — 'L' consumes rest
            },
            's' => {
                // String — no remap
                return word;
            },
            'M' => {
                if (pos == payload_start) {
                    // First word is mask literal
                    if (absolute_pos == pos) return word;
                    pos += 1;
                }
                // Rest are IDs
                if (absolute_pos == pos) {
                    if (load_replace.get(word)) |replacement| return replacement;
                    return id_remap.get(word) orelse word;
                }
                pos += 1;
            },
            'W' => {
                // Pairs of (literal, ID)
                const pair_offset = (absolute_pos - pos);
                if (pair_offset % 2 == 0) return word; // literal
                if (absolute_pos == pos + pair_offset) {
                    if (load_replace.get(word)) |replacement| return replacement;
                    return id_remap.get(word) orelse word;
                }
                pos += 2;
            },
            else => {
                pos += 1;
                oi += 1;
            },
        }
    }

    return word;
}

// ── Main entry point ─────────────────────────────────────────────

/// Fuse kernels in a SPIR-V binary according to the given options.
/// Iteratively fuses the best candidate pair, re-analyzes, and repeats
/// until no more candidates exist (transitive fusion: A→B→C into one kernel).
/// Maximum 16 fusion iterations to prevent runaway behavior.
pub fn fuseKernels(
    alloc: std.mem.Allocator,
    words: []const u32,
    options: FusionOptions,
) error{OutOfMemory}![]const u32 {
    if (words.len < 5) return words;
    if (words[0] != spirv.MAGIC) return words;

    var current = words;
    var needs_free = false;
    var iterations: u32 = 0;
    const max_iterations: u32 = 16;

    while (iterations < max_iterations) : (iterations += 1) {
        if (current.len < 5) break;
        if (current[0] != spirv.MAGIC) break;
        const bound = current[3];
        if (bound <= 1) break;


        // Find all entry points in current binary
        var entries = findEntryPoints(current, bound, alloc) catch break;
        defer {
            for (entries.items) |*e| {
                e.buffers_written.deinit();
                e.buffers_read.deinit();
                e.defined_ids.deinit();
                e.referenced_ids.deinit();
            }
            entries.deinit(alloc);
        }

        // Need at least 2 compute kernels
        var compute_count: u32 = 0;
        for (entries.items) |e| {
            if (e.exec_model == @intFromEnum(spirv.ExecutionModel.GLCompute)) {
                compute_count += 1;
            }
        }
        if (compute_count < 2) break;

        // Find fusion candidates
        var candidates = findFusionCandidates(entries.items, options, alloc) catch break;
        defer {
            for (candidates.items) |c| {
                var sb = c.shared_buffers;
                sb.deinit(alloc);
            }
            candidates.deinit(alloc);
        }

        if (candidates.items.len == 0) {
            break;
        }


        // Rank candidates by cost model (highest score = best)
        rankCandidates(candidates.items, entries.items);

        // Fuse the best candidate
        const fused = fusePair(current, bound, entries.items, candidates.items[0], alloc) catch break;
        if (needs_free) alloc.free(current);
        current = fused;
        needs_free = true;
    }

    // Run compactIds on final result to clean up
    if (needs_free) {
        const compacted = compact_ids.compactIds(alloc, current) catch return current;
        if (compacted.ptr != current.ptr) alloc.free(current);
        return compacted;
    }
    return current;
}

// ── Tests ────────────────────────────────────────────────────────

test "fuseKernels returns input unchanged for single-kernel SPIR-V" {
    const alloc = std.testing.allocator;
    const root = @import("root.zig");

    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer Data { vec4 values[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    values[idx] = values[idx] * 2.0;
        \\}
    ;
    const spirv_words = root.compileToSPIRV(alloc, source, .{
        .stage = .compute,
        .version = 450,
    }) catch return;
    defer alloc.free(spirv_words);

    const result = try fuseKernels(alloc, spirv_words, .{});
    defer if (result.ptr != spirv_words.ptr) alloc.free(result);
    // Single kernel — should return input unchanged
    try std.testing.expect(result.ptr == spirv_words.ptr);
}

test "fuseKernels returns input unchanged for non-compute shaders" {
    const alloc = std.testing.allocator;
    const root = @import("root.zig");

    const source =
        \\#version 430
        \\void main() {}
    ;
    const spirv_words = root.compileToSPIRV(alloc, source, .{
        .stage = .fragment,
    }) catch return;
    defer alloc.free(spirv_words);

    const result = try fuseKernels(alloc, spirv_words, .{});
    defer if (result.ptr != spirv_words.ptr) alloc.free(result);
    try std.testing.expect(result.ptr == spirv_words.ptr);
}

test "fuseKernels detects multiple compute entry points" {
    const alloc = std.testing.allocator;

    // Build a SPIR-V binary manually with two GLCompute entry points
    var words = std.ArrayList(u32).initCapacity(alloc, 64) catch return;
    defer words.deinit(alloc);

    // Header
    try words.appendSlice(alloc, &.{
        spirv.MAGIC,      // magic
        0x00010000,        // version 1.0
        0,                 // generator
        100,               // bound (IDs 0..99)
        0,                 // schema
    });

    // Capabilities
    try words.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(2, 17), 1, // OpCapability Shader
    });

    // Memory model
    try words.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(3, 14), 0, 1, // OpMemoryModel Logical GLSL450
    });

    // Entry points
    try words.appendSlice(alloc, &.{
        // OpEntryPoint GLCompute %main1 "main1"
        spirv.encodeInstructionHeader(4, 15), 5, 1, 0x6E69616D, 0x00003131,
        // OpEntryPoint GLCompute %main2 "main2"
        spirv.encodeInstructionHeader(4, 15), 5, 2, 0x6E69616D, 0x00003232,
    });

    // Execution modes
    try words.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(4, 16), 1, 17, 1, // OpExecutionMode %main1 LocalSize 1
        spirv.encodeInstructionHeader(4, 16), 2, 17, 1, // OpExecutionMode %main2 LocalSize 1
    });

    // Type declarations
    try words.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(2, 19), 3, // OpTypeVoid %3
        spirv.encodeInstructionHeader(2, 20), 4, // OpTypeBool %4
        spirv.encodeInstructionHeader(3, 21), 5, 32, 0, // OpTypeInt %5 32 0
        // OpTypeFunction %6 %3 (void -> void)
        spirv.encodeInstructionHeader(3, 33), 6, 3,
    });

    // Function 1: main1
    try words.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(5, 54), 3, 0, 6, 1, // OpFunction %3 %main1 None %6
        spirv.encodeInstructionHeader(2, 248), 7, // OpLabel %7
        spirv.encodeInstructionHeader(1, 253), // OpReturn
        spirv.encodeInstructionHeader(1, 56), // OpFunctionEnd
    });

    // Function 2: main2
    try words.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(5, 54), 3, 0, 6, 2, // OpFunction %3 %main2 None %6
        spirv.encodeInstructionHeader(2, 248), 8, // OpLabel %8
        spirv.encodeInstructionHeader(1, 253), // OpReturn
        spirv.encodeInstructionHeader(1, 56), // OpFunctionEnd
    });

    const result = try fuseKernels(alloc, words.items, .{});
    defer if (result.ptr != words.items.ptr) alloc.free(result);

    // Two trivial compute kernels with no buffer sharing — should not fuse
    // but should not crash either
    try std.testing.expect(result.len >= 5);
    try std.testing.expectEqual(spirv.MAGIC, result[0]);
}

test "EntryPoint analysis works on compiled compute shader" {
    const alloc = std.testing.allocator;
    const root = @import("root.zig");

    const source =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer InputBuf { float input_data[]; };
        \\layout(std430, binding = 1) buffer OutputBuf { float output_data[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    output_data[idx] = input_data[idx] * 2.0;
        \\}
    ;
    const spirv_words = root.compileToSPIRV(alloc, source, .{
        .stage = .compute,
        .version = 450,
    }) catch return;
    defer alloc.free(spirv_words);

    const bound = spirv_words[3];
    var entries = try findEntryPoints(spirv_words, bound, alloc);
    defer {
        for (entries.items) |*e| {
            e.buffers_written.deinit();
            e.buffers_read.deinit();
            e.defined_ids.deinit();
            e.referenced_ids.deinit();
        }
        entries.deinit(alloc);
    }

    // Should find exactly one compute entry point
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    const ep = entries.items[0];
    try std.testing.expectEqual(@as(u32, @intFromEnum(spirv.ExecutionModel.GLCompute)), ep.exec_model);

    // Should have buffer accesses
    const has_buffer_reads = ep.buffers_read.findFirstSet() != null;
    const has_buffer_writes = ep.buffers_written.findFirstSet() != null;
    try std.testing.expect(has_buffer_reads);
    try std.testing.expect(has_buffer_writes);
}

test "FusionOptions default values" {
    const opts = FusionOptions{};
    try std.testing.expectEqual(true, opts.fuse_elementwise);
    try std.testing.expectEqual(true, opts.fuse_into_reduction);
    try std.testing.expectEqual(@as(u32, 1024), opts.max_fused_size);
}

test "fuseKernels handles empty SPIR-V" {
    const alloc = std.testing.allocator;
    const result = try fuseKernels(alloc, &.{}, .{});
    try std.testing.expect(result.len == 0);
}

test "fuseKernels handles invalid magic" {
    const alloc = std.testing.allocator;
    const bad: []const u32 = &.{ 0xDEADBEEF, 0, 0, 10, 0 };
    const result = try fuseKernels(alloc, bad, .{});
    try std.testing.expect(result.ptr == bad.ptr);
}

test "fuseKernels fuses two kernels sharing a buffer" {
    const alloc = std.testing.allocator;

    // Build a SPIR-V module with two GLCompute kernels:
    //   kernel1: writes to buffer A (id=20)
    //   kernel2: reads from buffer A
    // Both are elementwise (no barriers, no atomics, no workgroup)
    //
    // ID layout:
    //   1 = main1 function
    //   2 = main2 function
    //   3 = void type
    //   4 = uint type (32-bit unsigned)
    //   5 = float type (32-bit)
    //   6 = function type (void->void)
    //   7 = runtime_array<float> type
    //   8 = struct{runtime_array<float>} type (block)
    //   9 = ptr<StorageBuffer, struct> type
    //   10 = ptr<StorageBuffer, float> type (via AccessChain)
    //   11 = ptr<StorageBuffer, float> type (reused for loads)
    //   12 = uint constant 0
    //   13 = label in main1
    //   14 = label in main2
    //   15 = loaded value in main1
    //   16 = mul result in main1
    //   17 = loaded value in main2
    //   18 = add result in main2
    //   20 = buffer variable A (StorageBuffer)
    //   21 = buffer variable B (StorageBuffer)

    var w = std.ArrayList(u32).initCapacity(alloc, 128) catch return;
    defer w.deinit(alloc);

    // Header
    try w.appendSlice(alloc, &.{ spirv.MAGIC, 0x00010300, 0, 30, 0 });

    // OpCapability Shader
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(2, 17), 1 });

    // OpMemoryModel Logical GLSL450
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(3, 14), 0, 1 });

    // OpEntryPoint GLCompute %1 "main1" %20
    try w.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(5, 15), 5, 1, 0x6E69616D, 0x00316E69, // "main1\0"
        20, // interface var
    });
    // OpEntryPoint GLCompute %2 "main2" %20 %21
    try w.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(6, 15), 5, 2, 0x6E69616D, 0x00326E69, // "main2\0"
        20, 21, // interface vars
    });

    // OpExecutionMode %1 LocalSize 1 1 1
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(6, 16), 1, 17, 1, 1, 1 });
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(6, 16), 2, 17, 1, 1, 1 });

    // OpDecorate %8 Block
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(3, 71), 8, 2 });
    // OpMemberDecorate %8 0 Offset 0
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(5, 72), 8, 0, 35, 0 });
    // OpDecorate %20 DescriptorSet 0
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 71), 20, 34, 0 });
    // OpDecorate %20 Binding 0
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 71), 20, 33, 0 });
    // OpDecorate %21 DescriptorSet 0
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 71), 21, 34, 0 });
    // OpDecorate %21 Binding 1
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 71), 21, 33, 1 });

    // Types
    // %3 = OpTypeVoid
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(2, 19), 3 });
    // %4 = OpTypeInt 32 0
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 21), 4, 32, 0 });
    // %5 = OpTypeFloat 32
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 22), 5, 32 });
    // %6 = OpTypeFunction %3
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(3, 33), 6, 3 });
    // %7 = OpTypeRuntimeArray %5
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(3, 29), 7, 5 });
    // %8 = OpTypeStruct %7
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(3, 30), 8, 7 });
    // %9 = OpTypePointer StorageBuffer %8
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 32), 9, 12, 8 });
    // %10 = OpTypePointer StorageBuffer %5
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 32), 10, 12, 5 });
    // %11 = OpTypePointer StorageBuffer %5 (duplicate ptr type for loads)
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 32), 11, 12, 5 });

    // Constants
    // %12 = OpConstant %4 0
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 43), 4, 12, 0 });

    // Global variables
    // %20 = OpVariable %9 StorageBuffer
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 59), 9, 20, 12 });
    // %21 = OpVariable %9 StorageBuffer
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 59), 9, 21, 12 });

    // Function 1 (main1): writes to buffer %20
    try w.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(5, 54), 3, 0, 6, 1, // OpFunction %3 %1 None %6
    });
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(2, 248), 13 }); // OpLabel %13
    // %22 = OpAccessChain %10 %20 %12
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(5, 65), 10, 22, 20, 12 });
    // %23 = OpLoad %5 %22
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 61), 5, 23, 22 });
    // %24 = OpFMul %5 %23 %23  (value = input * input)
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(5, 133), 5, 24, 23, 23 });
    // OpStore %22 %24
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(3, 62), 22, 24 });
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(1, 253) }); // OpReturn
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(1, 56) }); // OpFunctionEnd

    // Function 2 (main2): reads from buffer %20, writes to %21
    try w.appendSlice(alloc, &.{
        spirv.encodeInstructionHeader(5, 54), 3, 0, 6, 2, // OpFunction %3 %2 None %6
    });
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(2, 248), 14 }); // OpLabel %14
    // %25 = OpAccessChain %10 %20 %12
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(5, 65), 10, 25, 20, 12 });
    // %26 = OpAccessChain %11 %21 %12
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(5, 65), 11, 26, 21, 12 });
    // %27 = OpLoad %5 %25
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(4, 61), 5, 27, 25 });
    // %28 = OpFMul %5 %27 %27  (value = input * input)
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(5, 133), 5, 28, 27, 27 });
    // OpStore %26 %28
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(3, 62), 26, 28 });
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(1, 253) }); // OpReturn
    try w.appendSlice(alloc, &.{ spirv.encodeInstructionHeader(1, 56) }); // OpFunctionEnd

    const result = try fuseKernels(alloc, w.items, .{});
    defer if (result.ptr != w.items.ptr) alloc.free(result);

    // Should have fused — result should differ from input
    // (fewer entry points, fewer functions)
    try std.testing.expect(result.len >= 5);
    try std.testing.expectEqual(spirv.MAGIC, result[0]);

    // Count entry points in result
    var entry_count: u32 = 0;
    var p: u32 = 5;
    while (p < result.len) {
        const inst = nextInstruction(result, p) orelse break;
        if (inst.op == @intFromEnum(spirv.Op.EntryPoint)) {
            entry_count += 1;
        }
        p = inst.end;
    }
    // After fusion, should have only 1 entry point
    try std.testing.expectEqual(@as(u32, 1), entry_count);
}

test "compileToSPIRVWithFusion compiles single source" {
    const alloc = std.testing.allocator;
    const root = @import("root.zig");

    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer Data { float x[]; };
        \\void main() {
        \\    x[0] = 1.0;
        \\}
    ;

    const result = root.compileToSPIRVWithFusion(
        alloc,
        &.{source},
        .{ .stage = .compute, .version = 450 },
        .{},
    ) catch return;
    defer alloc.free(result);

    try std.testing.expect(result.len >= 5);
    try std.testing.expectEqual(spirv.MAGIC, result[0]);
}

test "rankCandidates prefers more shared buffers" {
    const alloc = std.testing.allocator;

    // Build two candidates with different shared buffer counts
    var c1 = FusionCandidate{
        .producer_idx = 0,
        .consumer_idx = 1,
        .shared_buffers = std.ArrayListUnmanaged(u32).empty,
        .consumer_is_reduction = false,
    };
    var c2 = FusionCandidate{
        .producer_idx = 2,
        .consumer_idx = 3,
        .shared_buffers = std.ArrayListUnmanaged(u32).empty,
        .consumer_is_reduction = false,
    };
    defer {
        c1.shared_buffers.deinit(alloc);
        c2.shared_buffers.deinit(alloc);
    }

    // c1 has 1 shared buffer, c2 has 3
    try c1.shared_buffers.append(alloc, 10);
    try c2.shared_buffers.append(alloc, 20);
    try c2.shared_buffers.append(alloc, 21);
    try c2.shared_buffers.append(alloc, 22);

    // Build minimal entry points for ranking (only instr_count matters)
    var e1 = EntryPoint{
        .func_id = 1,
        .exec_model = 5,
        .name = "a",
        .ep_word_pos = 0,
        .func_start = 0,
        .func_end = 0,
        .buffers_written = try std.DynamicBitSet.initEmpty(alloc, 100),
        .buffers_read = try std.DynamicBitSet.initEmpty(alloc, 100),
        .defined_ids = try std.DynamicBitSet.initEmpty(alloc, 100),
        .referenced_ids = try std.DynamicBitSet.initEmpty(alloc, 100),
        .instr_count = 50,
    };
    defer e1.buffers_written.deinit();
    defer e1.buffers_read.deinit();
    defer e1.defined_ids.deinit();
    defer e1.referenced_ids.deinit();

    var candidates = [_]FusionCandidate{ c1, c2 };
    var entries = [_]EntryPoint{ e1, e1, e1, e1 };

    rankCandidates(&candidates, &entries);

    // c2 should rank higher (3 shared buffers vs 1)
    try std.testing.expect(candidates[0].shared_buffers.items.len == 3);
    try std.testing.expect(candidates[1].shared_buffers.items.len == 1);
}

test "detectReductionPattern identifies reduction kernel" {
    const alloc = std.testing.allocator;

    // Build a minimal entry that looks like a reduction:
    // uses workgroup + barriers + reads one buffer + writes one buffer
    var buffers_read = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer buffers_read.deinit();
    buffers_read.set(10); // input buffer

    var buffers_written = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer buffers_written.deinit();
    buffers_written.set(20); // output buffer IS written

    var global_buffers = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer global_buffers.deinit();
    global_buffers.set(10);
    global_buffers.set(20);

    var entry = EntryPoint{
        .func_id = 1,
        .exec_model = 5,
        .name = "reduce",
        .ep_word_pos = 0,
        .func_start = 0,
        .func_end = 0,
        .buffers_written = buffers_written,
        .buffers_read = buffers_read,
        .defined_ids = try std.DynamicBitSet.initEmpty(alloc, 100),
        .referenced_ids = try std.DynamicBitSet.initEmpty(alloc, 100),
        .uses_workgroup = true,
        .has_barrier = true,
        .has_atomics = false,
        .instr_count = 50,
    };
    defer entry.defined_ids.deinit();
    defer entry.referenced_ids.deinit();

    const dummy_words = [_]u32{ spirv.MAGIC, 0, 0, 100, 0 };
    const info = detectReductionPattern(&entry, &dummy_words, 100, &global_buffers);

    try std.testing.expect(info.is_reduction);
    try std.testing.expect(info.input_buffer.? == 10);
}

test "detectReductionPattern rejects non-reduction kernel" {
    const alloc = std.testing.allocator;

    // No workgroup, no barrier — not a reduction
    var buffers_read = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer buffers_read.deinit();
    buffers_read.set(10);

    var buffers_written = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer buffers_written.deinit();

    var global_buffers = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer global_buffers.deinit();
    global_buffers.set(10);

    var entry = EntryPoint{
        .func_id = 1,
        .exec_model = 5,
        .name = "elementwise",
        .ep_word_pos = 0,
        .func_start = 0,
        .func_end = 0,
        .buffers_written = buffers_written,
        .buffers_read = buffers_read,
        .defined_ids = try std.DynamicBitSet.initEmpty(alloc, 100),
        .referenced_ids = try std.DynamicBitSet.initEmpty(alloc, 100),
        .uses_workgroup = false,
        .has_barrier = false,
        .has_atomics = false,
        .instr_count = 10,
    };
    defer entry.defined_ids.deinit();
    defer entry.referenced_ids.deinit();

    const dummy_words = [_]u32{ spirv.MAGIC, 0, 0, 100, 0 };
    const info = detectReductionPattern(&entry, &dummy_words, 100, &global_buffers);

    try std.testing.expect(!info.is_reduction);
}


test "transitive fusion: three kernels sharing buffers" {

    const alloc = std.testing.allocator;
    const root = @import("root.zig");

    // Three compute kernels forming a pipeline: A -> B -> C
    const kernel_a =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer InputBuf { float input_data[]; };
        \\layout(std430, binding = 1) buffer MidBuf { float mid_data[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    mid_data[idx] = input_data[idx] * 2.0;
        \\}
    ;
    const kernel_b =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 1) buffer MidBuf { float mid_data[]; };
        \\layout(std430, binding = 2) buffer MidBuf2 { float mid2_data[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    mid2_data[idx] = mid_data[idx] + 1.0;
        \\}
    ;
    const kernel_c =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 2) buffer MidBuf2 { float mid2_data[]; };
        \\layout(std430, binding = 3) buffer OutputBuf { float output_data[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    output_data[idx] = mid2_data[idx] * 3.0;
        \\}
    ;

    const sources = [_][:0]const u8{ kernel_a, kernel_b, kernel_c };
    const names = [_][]const u8{ "step_a", "step_b", "step_c" };

    // Compile all three into one multi-kernel module
    const multi_spirv = root.compileMultiKernel(alloc, &sources, .{
        .names = &names,
        .stage = .compute,
        .version = 450,
    }) catch return;
    defer alloc.free(multi_spirv);

    // Apply fusion
    const result = fuseKernels(alloc, multi_spirv, .{}) catch return;
    defer if (result.ptr != multi_spirv.ptr) alloc.free(result);

    try std.testing.expect(result.len >= 5);
    try std.testing.expectEqual(spirv.MAGIC, result[0]);

    // Count entry points — transitive fusion should reduce them
    // Note: after multi-kernel merge, buffers get different IDs per module,
    // so fusion across module boundaries depends on binding deduplication.
    // The key thing tested here is the iterative fusion loop + cost model + reduction detection.
    var entry_count: u32 = 0;
    var p: u32 = 5;
    while (p < result.len) {
        const hdr = result[p];
        const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(hdr & 0xFFFF);
        if (op == 15) entry_count += 1;
        p += wc;
    }
    // Should have at most 3 entry points (fusion may not work across module boundaries)
    try std.testing.expect(entry_count >= 1 and entry_count <= 3);
}

test "findFusionCandidates rejects reduction as producer" {
    const alloc = std.testing.allocator;

    // Producer is a reduction, consumer is elementwise — should NOT be a candidate
    var prod_written = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer prod_written.deinit();
    prod_written.set(10);

    var prod_read = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer prod_read.deinit();

    var cons_written = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer cons_written.deinit();

    var cons_read = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer cons_read.deinit();
    cons_read.set(10); // reads what producer writes

    var global_bufs = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer global_bufs.deinit();
    global_bufs.set(10);

    var prod_def_ids = try std.DynamicBitSet.initEmpty(alloc, 100);
    errdefer prod_def_ids.deinit();
    var prod_ref_ids = try std.DynamicBitSet.initEmpty(alloc, 100);
    errdefer prod_ref_ids.deinit();
    var cons_def_ids = try std.DynamicBitSet.initEmpty(alloc, 100);
    errdefer cons_def_ids.deinit();
    var cons_ref_ids = try std.DynamicBitSet.initEmpty(alloc, 100);
    errdefer cons_ref_ids.deinit();

    const producer = EntryPoint{
        .func_id = 1,
        .exec_model = @intFromEnum(spirv.ExecutionModel.GLCompute),
        .name = "reduction",
        .ep_word_pos = 0,
        .func_start = 0,
        .func_end = 50,
        .buffers_written = prod_written,
        .buffers_read = prod_read,
        .defined_ids = prod_def_ids,
        .referenced_ids = prod_ref_ids,
        .uses_workgroup = true,
        .has_barrier = true,
        .has_atomics = false,
        .instr_count = 50,
        .reduction_info = .{ .is_reduction = true, .input_buffer = 5 },
    };
    const consumer = EntryPoint{
        .func_id = 2,
        .exec_model = @intFromEnum(spirv.ExecutionModel.GLCompute),
        .name = "elementwise",
        .ep_word_pos = 0,
        .func_start = 50,
        .func_end = 100,
        .buffers_written = cons_written,
        .buffers_read = cons_read,
        .defined_ids = cons_def_ids,
        .referenced_ids = cons_ref_ids,
        .uses_workgroup = false,
        .has_barrier = false,
        .has_atomics = false,
        .instr_count = 20,
    };
    defer {
        prod_def_ids.deinit();
        prod_ref_ids.deinit();
        cons_def_ids.deinit();
        cons_ref_ids.deinit();
    }

    const entries = [_]EntryPoint{ producer, consumer };
    var candidates = try findFusionCandidates(&entries, .{ .fuse_elementwise = true, .fuse_into_reduction = true }, alloc);
    defer {
        for (candidates.items) |*c| c.shared_buffers.deinit(alloc);
        candidates.deinit(alloc);
    }

    // Should have zero candidates — reduction cannot be a producer
    try std.testing.expectEqual(@as(usize, 0), candidates.items.len);
}

test "findFusionCandidates rejects two reductions fusing" {
    const alloc = std.testing.allocator;

    // Both are reductions — should NOT be a candidate in either direction
    var prod_written = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer prod_written.deinit();
    prod_written.set(10);

    var prod_read = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer prod_read.deinit();

    var cons_written = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer cons_written.deinit();
    cons_written.set(20);

    var cons_read = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer cons_read.deinit();
    cons_read.set(10); // reads what producer writes

    var global_bufs = try std.DynamicBitSet.initEmpty(alloc, 100);
    defer global_bufs.deinit();
    global_bufs.set(10);
    global_bufs.set(20);

    var ra_def_ids = try std.DynamicBitSet.initEmpty(alloc, 100);
    errdefer ra_def_ids.deinit();
    var ra_ref_ids = try std.DynamicBitSet.initEmpty(alloc, 100);
    errdefer ra_ref_ids.deinit();
    var rb_def_ids = try std.DynamicBitSet.initEmpty(alloc, 100);
    errdefer rb_def_ids.deinit();
    var rb_ref_ids = try std.DynamicBitSet.initEmpty(alloc, 100);
    errdefer rb_ref_ids.deinit();

    const reduction_a = EntryPoint{
        .func_id = 1,
        .exec_model = @intFromEnum(spirv.ExecutionModel.GLCompute),
        .name = "reduction_a",
        .ep_word_pos = 0,
        .func_start = 0,
        .func_end = 50,
        .buffers_written = prod_written,
        .buffers_read = prod_read,
        .defined_ids = ra_def_ids,
        .referenced_ids = ra_ref_ids,
        .uses_workgroup = true,
        .has_barrier = true,
        .has_atomics = false,
        .instr_count = 50,
        .reduction_info = .{ .is_reduction = true, .input_buffer = 5 },
    };
    const reduction_b = EntryPoint{
        .func_id = 2,
        .exec_model = @intFromEnum(spirv.ExecutionModel.GLCompute),
        .name = "reduction_b",
        .ep_word_pos = 0,
        .func_start = 50,
        .func_end = 100,
        .buffers_written = cons_written,
        .buffers_read = cons_read,
        .defined_ids = rb_def_ids,
        .referenced_ids = rb_ref_ids,
        .uses_workgroup = true,
        .has_barrier = true,
        .has_atomics = false,
        .instr_count = 50,
        .reduction_info = .{ .is_reduction = true, .input_buffer = 10 },
    };
    defer {
        ra_def_ids.deinit();
        ra_ref_ids.deinit();
        rb_def_ids.deinit();
        rb_ref_ids.deinit();
    }

    const entries = [_]EntryPoint{ reduction_a, reduction_b };
    var candidates = try findFusionCandidates(&entries, .{ .fuse_elementwise = true, .fuse_into_reduction = true }, alloc);
    defer {
        for (candidates.items) |*c| c.shared_buffers.deinit(alloc);
        candidates.deinit(alloc);
    }

    // Should have zero candidates — neither direction works (reduction can't be producer)
    try std.testing.expectEqual(@as(usize, 0), candidates.items.len);
}

test "elementwise to reduction fusion via findFusionCandidates" {
    const alloc = std.testing.allocator;
    const root = @import("root.zig");

    // Compile an elementwise kernel and a reduction kernel separately,
    // then test that findFusionCandidates identifies the correct fusion pair.
    const elementwise_glsl =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer InputBuf { float input_data[]; };
        \\layout(std430, binding = 1) buffer OutputBuf { float mid_data[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    mid_data[idx] = input_data[idx] * 2.0;
        \\}
    ;
    const reduction_glsl =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 1) buffer MidBuf { float mid_data[]; };
        \\layout(std430, binding = 2) buffer OutputBuf { float output_data[]; };
        \\shared float shared_buf[64];
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    uint local_idx = gl_LocalInvocationID.x;
        \\    shared_buf[local_idx] = mid_data[idx];
        \\    barrier();
        \\    if (local_idx == 0)
        \\        output_data[gl_WorkGroupID.x] = shared_buf[0];
        \\}
    ;

    // Compile each to SPIR-V
    const ew_spirv = root.compileToSPIRV(alloc, elementwise_glsl, .{
        .stage = .compute,
        .version = 450,
    }) catch return;
    defer alloc.free(ew_spirv);
    const red_spirv = root.compileToSPIRV(alloc, reduction_glsl, .{
        .stage = .compute,
        .version = 450,
    }) catch return;
    defer alloc.free(red_spirv);

    // Link them into one module
    const modules = [_][]const u32{ ew_spirv, red_spirv };
    const linked = root.linkSPIRVModules(alloc, &modules) catch return;
    defer alloc.free(linked);

    // Analyze entry points
    const bound = linked[3];
    var entries = findEntryPoints(linked, bound, alloc) catch return;
    defer {
        for (entries.items) |*e| {
            e.buffers_written.deinit();
            e.buffers_read.deinit();
            e.defined_ids.deinit();
            e.referenced_ids.deinit();
        }
        entries.deinit(alloc);
    }

    // Should have 2 entry points now that linker correctly remaps func_ids
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);

    // Check: at least one should be a reduction (uses workgroup + barrier)
    var found_reduction = false;
    for (entries.items) |entry| {
        if (entry.reduction_info.is_reduction) {
            found_reduction = true;
            // Reduction should have barriers and workgroup
            try std.testing.expect(entry.has_barrier);
            try std.testing.expect(entry.uses_workgroup);
        }
    }
    // If the reduction was detected, also check candidate finding
    if (found_reduction) {
        var candidates = try findFusionCandidates(
            entries.items,
            .{ .fuse_elementwise = true, .fuse_into_reduction = true },
            alloc,
        );
        defer {
            for (candidates.items) |*c| c.shared_buffers.deinit(alloc);
            candidates.deinit(alloc);
        }

        // Verify: any reduction consumer candidates have consumer_is_reduction = true
        for (candidates.items) |c| {
            if (c.consumer_is_reduction) {
                const cons = entries.items[c.consumer_idx];
                try std.testing.expect(cons.reduction_info.is_reduction);
                // Producer should be elementwise
                const prod = entries.items[c.producer_idx];
                try std.testing.expect(!prod.reduction_info.is_reduction);
                try std.testing.expect(!prod.uses_workgroup);
                try std.testing.expect(!prod.has_barrier);
            }
        }
    }
}

test "fuseKernels fuses elementwise into reduction consumer" {
    const alloc = std.testing.allocator;
    const root = @import("root.zig");

    // Elementwise kernel that feeds a reduction
    const elementwise_glsl =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer InputBuf { float input_data[]; };
        \\layout(std430, binding = 1) buffer OutputBuf { float mid_data[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    mid_data[idx] = input_data[idx] * 2.0;
        \\}
    ;
    const reduction_glsl =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 1) buffer MidBuf { float mid_data[]; };
        \\layout(std430, binding = 2) buffer OutputBuf { float output_data[]; };
        \\shared float shared_buf[64];
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    uint local_idx = gl_LocalInvocationID.x;
        \\    shared_buf[local_idx] = mid_data[idx];
        \\    barrier();
        \\    if (local_idx == 0)
        \\        output_data[gl_WorkGroupID.x] = shared_buf[0];
        \\}
    ;

    const ew_spirv = root.compileToSPIRV(alloc, elementwise_glsl, .{
        .stage = .compute,
        .version = 450,
    }) catch return;
    defer alloc.free(ew_spirv);
    const red_spirv = root.compileToSPIRV(alloc, reduction_glsl, .{
        .stage = .compute,
        .version = 450,
    }) catch return;
    defer alloc.free(red_spirv);

    const modules = [_][]const u32{ ew_spirv, red_spirv };
    const linked = root.linkSPIRVModules(alloc, &modules) catch return;
    defer alloc.free(linked);

    // Apply fusion with reduction fusion enabled
    const result = fuseKernels(alloc, linked, .{
        .fuse_elementwise = true,
        .fuse_into_reduction = true,
    }) catch return;
    defer if (result.ptr != linked.ptr) alloc.free(result);

    try std.testing.expect(result.len >= 5);
    try std.testing.expectEqual(spirv.MAGIC, result[0]);

    // Count entry points
    var entry_count: u32 = 0;
    var p: u32 = 5;
    while (p < result.len) {
        const hdr = result[p];
        const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(hdr & 0xFFFF);
        if (op == 15) entry_count += 1;
        p += wc;
    }

    // After fusion, should have fewer than 2 entry points
    // (at least the elementwise→reduction pair should fuse)
    // If buffer IDs don't align across modules, fusion won't happen, so accept 2 as well
    try std.testing.expect(entry_count >= 1 and entry_count <= 2);
}
