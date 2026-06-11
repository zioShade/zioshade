// SPDX-License-Identifier: MIT OR Apache-2.0
// SPIR-V optimization passes. Split from compact_ids.zig.
// Only needed by codegen.zig for the full optimization pipeline.
const std = @import("std");
const compact_ids = @import("compact_ids.zig");

/// Dead code elimination: remove instructions whose result ID is never referenced.
/// Returns the same slice if nothing changed, or a new shorter slice with dead instructions removed.
pub fn deadCodeElim(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    const mark = struct {
        fn markId(bs: *std.DynamicBitSet, w: u32, bnd: u32) void {
            if (w >= 1 and w < bnd) bs.set(w);
        }
    }.markId;

    // Collect only REFERENCES (not definitions)
    var referenced = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer referenced.deinit();

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const inst_end = pos + wc;
        if (inst_end > words.len) break;

        const info = compact_ids.getOpInfo(opcode) orelse { pos = inst_end; continue; };
        var wi: u32 = pos + 1;

        // result_type is a REFERENCE
        switch (info.fixed) {
            1 => { if (wi < inst_end) { mark(&referenced, words[wi], bound); wi += 1; } },
            2 => {
                if (wi < inst_end) { mark(&referenced, words[wi], bound); wi += 1; }
                if (wi < inst_end) { wi += 1; } // skip result (definition)
            },
            3 => { if (wi < inst_end) { wi += 1; } }, // skip result (definition)
            else => {},
        }

        for (info.ops) |ch| {
            if (wi >= inst_end) break;
            switch (ch) {
                'i' => { mark(&referenced, words[wi], bound); wi += 1; },
                'l' => { wi += 1; },
                'I' => { while (wi < inst_end) : (wi += 1) mark(&referenced, words[wi], bound); },
                'L' => { wi = inst_end; },
                's' => { wi = inst_end; },
                'M' => { if (wi < inst_end) { wi += 1; while (wi < inst_end) : (wi += 1) mark(&referenced, words[wi], bound); } },
                'W' => { while (wi + 1 < inst_end) { wi += 1; mark(&referenced, words[wi], bound); wi += 1; } if (wi < inst_end) wi += 1; },
                'E' => { while (wi < inst_end) { const w = words[wi]; wi += 1; if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (wi < inst_end) : (wi += 1) mark(&referenced, words[wi], bound); },
                else => {},
            }
        }
        pos = inst_end;
    }

    // Identify side-effect-free dead instructions and remove them (fixpoint)
    const is_dead_safe = struct {
        fn check(op: u16) bool {
            return switch (op) {
                41, 42, 43, 44, 48, 49, 50, 51, 52 => true, // Constants + spec consts (SpecConstantTrue/False/Composite/Op)
                61 => true, // Load
                65 => true, // AccessChain
                77, 79, 80, 81, 82, 83 => true, // Composite ops + CopyObject
                84 => true, // Transpose
                86 => true, // OpSampledImage (pure — safe if result unused)
                100, 103, 104, 105, 106, 107 => true, // Image queries
                87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98 => true, // Image sampling (pure — safe to remove if result unused)
                109, 110, 111, 112, 113, 114, 115, 124 => true, // Conversions (including UConvert, FConvert)
                126, 127 => true, // Negate
                128...133, 135...138, 141, 142 => true, // Arithmetic
                143 => true, // OpMatrixTimesScalar
                144...148 => true, // Matrix/vector ops
                154...157 => true, // All/Any/IsNan/IsInf
                166...168, 170, 171 => true, // LogicalOr/And/Not/Equal/NotEqual
                169 => true, // Select
                172, 173, 174, 175, 176, 177, 178, 179 => true, // Integer comparisons
                180, 182, 184, 186, 188, 190 => true, // FOrd comparisons
                194, 195, 196, 197, 198, 199, 200 => true, // Shift + Bit ops
                201, 202, 203 => true, // OpBitFieldInsert, OpBitFieldSExtract, OpBitFieldUExtract (pure)
                207...215 => true, // Derivatives
                12 => true, // ExtInst
                // Type instructions (result_only, no side effects)
                19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 32, 33 => true, // Types
                39 => true, // TypeForwardPointer
                4472, 5341, 4163 => true, // TypeRayQueryKHR, TypeAccelerationStructureKHR, TypeTensorARM
                245 => true, // OpPhi (safe to remove if result unused)
                59 => true, // OpVariable (Function-local only — safe to remove if unreferenced)
                4428, 4429 => true, // OpSubgroupAllKHR, OpSubgroupAnyKHR (pure)
                5340 => true, // OpRayQueryGetIntersectionTriangleVertexPositionsKHR (pure query)
                11 => true, // OpExtInstImport (no side effects, result_only)
                else => false,
            };
        }
    }.check;

    // Iterative DCE
    var current_words = words;
    var current_needs_free = false;
    for (0..15) |_| {
        // Find dead instructions
        var any_removed = false;
        var result = std.ArrayList(u32).initCapacity(alloc, current_words.len) catch return current_words;
        // Copy header
        result.appendSliceAssumeCapacity(current_words[0..5]);

        pos = 5;
        while (pos < current_words.len) {
            const hdr = current_words[pos];
            const wc: u32 = hdr >> 16;
            const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            const inst_end = pos + wc;
            if (inst_end > current_words.len) break;

            // Check if this instruction is dead
            if (is_dead_safe(opcode)) {
                const info = compact_ids.getOpInfo(opcode) orelse {
                    result.appendSliceAssumeCapacity(current_words[pos..inst_end]);
                    pos = inst_end;
                    continue;
                };
                var result_id: ?u32 = null;
                switch (info.fixed) {
                    2 => { if (pos + 2 < inst_end) result_id = current_words[pos + 2]; },
                    3 => { if (pos + 1 < inst_end) result_id = current_words[pos + 1]; },
                    else => {},
                }
                if (result_id) |rid| {
                    if (rid >= 1 and rid < bound and !referenced.isSet(rid)) {
                        // Dead instruction — skip it
                        any_removed = true;
                        pos = inst_end;
                        continue;
                    }
                }
            }

            result.appendSliceAssumeCapacity(current_words[pos..inst_end]);
            pos = inst_end;
        }

        if (!any_removed) {
            result.deinit(alloc);
            break;
        }

        // Rebuild referenced set for next iteration
        const new_words = result.toOwnedSlice(alloc) catch return current_words;
        var ri: usize = 0;
        while (ri < bound) : (ri += 1) referenced.unset(ri);
        pos = 5;
        while (pos < new_words.len) {
            const hdr2 = new_words[pos];
            const wc2: u32 = hdr2 >> 16;
            const opcode2: u16 = @truncate(hdr2 & 0xFFFF);
            if (wc2 == 0) break;
            const ie2 = pos + wc2;
            if (ie2 > new_words.len) break;
            const info2 = compact_ids.getOpInfo(opcode2) orelse { pos = ie2; continue; };
            var wi2: u32 = pos + 1;
            switch (info2.fixed) {
                1 => { if (wi2 < ie2) { mark(&referenced, new_words[wi2], bound); wi2 += 1; } },
                2 => { if (wi2 < ie2) { mark(&referenced, new_words[wi2], bound); wi2 += 1; } if (wi2 < ie2) wi2 += 1; },
                3 => { if (wi2 < ie2) wi2 += 1; },
                else => {},
            }
            for (info2.ops) |ch| {
                if (wi2 >= ie2) break;
                switch (ch) {
                    'i' => { mark(&referenced, new_words[wi2], bound); wi2 += 1; },
                    'l' => { wi2 += 1; },
                    'I' => { while (wi2 < ie2) : (wi2 += 1) mark(&referenced, new_words[wi2], bound); },
                    'L' => { wi2 = ie2; },
                    's' => { wi2 = ie2; },
                    'M' => { if (wi2 < ie2) { wi2 += 1; while (wi2 < ie2) : (wi2 += 1) mark(&referenced, new_words[wi2], bound); } },
                    'W' => { while (wi2 + 1 < ie2) { wi2 += 1; mark(&referenced, new_words[wi2], bound); wi2 += 1; } if (wi2 < ie2) wi2 += 1; },
                    'E' => { while (wi2 < ie2) { const w = new_words[wi2]; wi2 += 1; if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (wi2 < ie2) : (wi2 += 1) mark(&referenced, new_words[wi2], bound); },
                    else => {},
                }
            }
            pos = ie2;
        }
        // Use new_words as input for next iteration
        if (current_needs_free) alloc.free(current_words);
        current_words = new_words;
        current_needs_free = true;
    }

    // Dead store elimination: remove function-local variables that are only stored to, never loaded.
    // Phase 1: Identify all function-local variables
    // Phase 2: Track which are ever read from (OpLoad, OpAccessChain, OpCopyMemory, etc.)
    // Phase 3: Remove dead variables + their stores, then re-run DCE
    {
        const current_bound = current_words[3];
        if (current_bound > 1) {
            // Collect function-local variable IDs
            var func_vars = try std.DynamicBitSet.initEmpty(alloc, current_bound);
            defer func_vars.deinit();

            pos = 5;
            while (pos < current_words.len) {
                const hdr = current_words[pos];
                const wc: u32 = hdr >> 16;
                const opcode: u16 = @truncate(hdr & 0xFFFF);
                if (wc == 0) break;
                if (opcode == 59 and wc >= 4) { // OpVariable
                    // Layout: result_type, result_id, storage_class
                    const storage_class = current_words[pos + 3];
                    if (storage_class == 7 or storage_class == 6) { // Function or Private storage class
                        const var_id = current_words[pos + 2];
                        if (var_id >= 1 and var_id < current_bound) {
                            func_vars.set(var_id);
                        }
                    }
                }
                pos += wc;
            }

            if (func_vars.count() > 0) {
                // Track which function vars are ever READ from
                var loaded_vars = try std.DynamicBitSet.initEmpty(alloc, current_bound);
                defer loaded_vars.deinit();
                // Track which function vars are WRITTEN to
                var stored_vars = try std.DynamicBitSet.initEmpty(alloc, current_bound);
                defer stored_vars.deinit();

                pos = 5;
                while (pos < current_words.len) {
                    const hdr = current_words[pos];
                    const wc: u32 = hdr >> 16;
                    const opcode: u16 = @truncate(hdr & 0xFFFF);
                    if (wc == 0) break;
                    const inst_end = pos + wc;
                    if (inst_end > current_words.len) break;

                    switch (opcode) {
                        61 => { // OpLoad: ptr is operand 2 (after result_type, result_id)
                            if (wc >= 4) {
                                const ptr = current_words[pos + 3];
                                if (ptr < current_bound and func_vars.isSet(ptr)) {
                                    loaded_vars.set(ptr);
                                }
                            }
                        },
                        62 => { // OpStore: ptr is operand 1 (no result)
                            if (wc >= 3) {
                                const ptr = current_words[pos + 1];
                                if (ptr < current_bound and func_vars.isSet(ptr)) {
                                    stored_vars.set(ptr);
                                }
                            }
                        },
                        65 => { // OpAccessChain: base is operand 3
                            // Don't mark as loaded/stored yet — track AC results separately
                            // AC just computes a pointer; actual read/write is at use site
                        },
                        46 => { // OpCopyMemory: dst=op1, src=op2
                            if (wc >= 3) {
                                const dst = current_words[pos + 1];
                                const src = current_words[pos + 2];
                                if (dst < current_bound and func_vars.isSet(dst)) stored_vars.set(dst);
                                if (src < current_bound and func_vars.isSet(src)) loaded_vars.set(src);
                            }
                        },
                        12 => { // OpExtInst: may implicitly write to pointer args (Modf, Frexp, etc.)
                            // Mark all ID operands as loaded to be safe (conservative)
                            // Layout: result_type(1), result_id(1), set(1), literal(1), then IDs...
                            if (wc >= 6) {
                                var ei: u32 = pos + 5; // skip header, result_type, result_id, set, instruction literal
                                while (ei < inst_end) : (ei += 1) {
                                    const op = current_words[ei];
                                    if (op < current_bound and func_vars.isSet(op)) {
                                        loaded_vars.set(op);
                                        stored_vars.set(op); // also treated as store (Modf writes to ptr)
                                    }
                                }
                            }
                        },
                        57 => { // OpFunctionCall: args after func_id may be read/written
                            // Layout: result_type, result_id, func_id, arg1, arg2, ...
                            if (wc >= 5) {
                                var ai: u32 = pos + 4; // skip header, result_type, result_id, func_id
                                while (ai < inst_end) : (ai += 1) {
                                    const op = current_words[ai];
                                    if (op < current_bound and func_vars.isSet(op)) {
                                        loaded_vars.set(op);
                                        stored_vars.set(op); // conservatively mark as stored
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                    pos = inst_end;
                }

                // Phase 2: Track AccessChain results transitively
                // Build map: AC_result_id -> root_var_id (the function-local var it ultimately derives from)
                var ac_to_root = std.AutoHashMapUnmanaged(u32, u32).empty;
                defer ac_to_root.deinit(alloc);

                // Build AC result -> root var map (transitive)
                pos = 5;
                while (pos < current_words.len) {
                    const hdr = current_words[pos];
                    const wc: u32 = hdr >> 16;
                    const opcode: u16 = @truncate(hdr & 0xFFFF);
                    if (wc == 0) break;
                    const inst_end = pos + wc;
                    if (inst_end > current_words.len) break;

                    if (opcode == 65 and wc >= 5) { // OpAccessChain
                        const ac_result = current_words[pos + 2];
                        const ac_base_ptr = current_words[pos + 3];
                        // Resolve root: if base is a func var, it's the root
                        if (ac_base_ptr < current_bound and func_vars.isSet(ac_base_ptr)) {
                            try ac_to_root.put(alloc, ac_result, ac_base_ptr);
                        } else if (ac_to_root.get(ac_base_ptr)) |root| {
                            try ac_to_root.put(alloc, ac_result, root);
                        }
                    }
                    pos = inst_end;
                }

                // Now scan for loads/stores of AC results and propagate to root vars
                pos = 5;
                while (pos < current_words.len) {
                    const hdr = current_words[pos];
                    const wc: u32 = hdr >> 16;
                    const opcode: u16 = @truncate(hdr & 0xFFFF);
                    if (wc == 0) break;
                    const inst_end = pos + wc;
                    if (inst_end > current_words.len) break;

                    switch (opcode) {
                        61 => { // OpLoad: check if ptr is an AC result from a func var
                            if (wc >= 4) {
                                const ptr = current_words[pos + 3];
                                if (ac_to_root.get(ptr)) |root| {
                                    loaded_vars.set(root);
                                }
                            }
                        },
                        62 => { // OpStore: check if ptr is an AC result from a func var
                            if (wc >= 3) {
                                const ptr = current_words[pos + 1];
                                if (ac_to_root.get(ptr)) |root| {
                                    stored_vars.set(root);
                                }
                            }
                        },
                        57 => { // OpFunctionCall: args may be AC results -> conservatively load+store
                            if (wc >= 5) {
                                var ai: u32 = pos + 4;
                                while (ai < inst_end) : (ai += 1) {
                                    const op = current_words[ai];
                                    if (ac_to_root.get(op)) |root| {
                                        loaded_vars.set(root);
                                        stored_vars.set(root);
                                    }
                                }
                            }
                        },
                        12 => { // OpExtInst: pointer args may be AC results
                            if (wc >= 6) {
                                var ei: u32 = pos + 5;
                                while (ei < inst_end) : (ei += 1) {
                                    const op = current_words[ei];
                                    if (ac_to_root.get(op)) |root| {
                                        loaded_vars.set(root);
                                        stored_vars.set(root);
                                    }
                                }
                            }
                        },
                        37 => { // OpCopyMemory
                            if (wc >= 3) {
                                const dst = current_words[pos + 1];
                                const src = current_words[pos + 2];
                                if (ac_to_root.get(dst)) |root| stored_vars.set(root);
                                if (ac_to_root.get(src)) |root| loaded_vars.set(root);
                            }
                        },
                        else => {},
                    }
                    pos = inst_end;
                }

                // Identify dead vars: stored to but never loaded
                var dead_vars = try std.DynamicBitSet.initEmpty(alloc, current_bound);
                defer dead_vars.deinit();
                var dvi: usize = 0;
                while (dvi < current_bound) : (dvi += 1) {
                    if (func_vars.isSet(dvi) and stored_vars.isSet(dvi) and !loaded_vars.isSet(dvi)) {
                        dead_vars.set(dvi);
                    }
                }

                if (dead_vars.count() > 0) {
                    // Remove dead variable definitions and their stores
                    var dse_result = std.ArrayList(u32).initCapacity(alloc, current_words.len) catch return current_words;
                    dse_result.appendSliceAssumeCapacity(current_words[0..5]);

                    pos = 5;
                    while (pos < current_words.len) {
                        const hdr = current_words[pos];
                        const wc: u32 = hdr >> 16;
                        const opcode: u16 = @truncate(hdr & 0xFFFF);
                        if (wc == 0) break;
                        const inst_end = pos + wc;
                        if (inst_end > current_words.len) break;

                        var skip = false;
                        if (opcode == 59 and wc >= 3) { // OpVariable
                            const var_id = current_words[pos + 2];
                            if (var_id < current_bound and dead_vars.isSet(var_id)) skip = true;
                        }
                        if (opcode == 62 and wc >= 2) { // OpStore
                            const ptr = current_words[pos + 1];
                            if (ptr < current_bound and dead_vars.isSet(ptr)) skip = true;
                            // Also check if ptr is an AC result from a dead var
                            if (!skip) {
                                if (ac_to_root.get(ptr)) |root| {
                                    if (root < current_bound and dead_vars.isSet(root)) skip = true;
                                }
                            }
                        }
                        if (opcode == 65 and wc >= 5) { // OpAccessChain
                            const base = current_words[pos + 3];
                            // Remove if base is a dead var
                            if (base < current_bound and dead_vars.isSet(base)) skip = true;
                            // Also remove if base is an AC result from a dead var
                            if (!skip) {
                                if (ac_to_root.get(base)) |root| {
                                    if (root < current_bound and dead_vars.isSet(root)) skip = true;
                                }
                            }
                        }

                        if (!skip) {
                            dse_result.appendSliceAssumeCapacity(current_words[pos..inst_end]);
                        }
                        pos = inst_end;
                    }

                    const dse_words = dse_result.toOwnedSlice(alloc) catch return current_words;
                    // Re-run DCE to clean up cascading dead code (e.g., values only used in eliminated stores)
                    const re_dce = deadCodeElim(alloc, dse_words) catch return dse_words;
                    if (re_dce.ptr != dse_words.ptr) alloc.free(dse_words);
                    if (current_words.ptr != words.ptr) alloc.free(current_words);
                    return re_dce;
                }
            }
        }
    }

    // Store-to-load forwarding within basic blocks
    // For each block: track last store per pointer. When OpLoad is seen for a stored pointer,
    // replace all uses of the load result with the stored value.
    // IMPORTANT: when a store targets an AccessChain result (component store), invalidate
    // the forwarding for the base variable, since the variable's value has changed.
    {
        const fwd_bound = current_words[3];
        if (fwd_bound > 1) {
            // Build AC result -> base var map for invalidation
            var ac_to_base = std.AutoHashMapUnmanaged(u32, u32).empty; // ac_result -> base_var
            defer ac_to_base.deinit(alloc);
            pos = 5;
            while (pos < current_words.len) {
                const hdr = current_words[pos];
                const wc: u32 = hdr >> 16;
                const opcode: u16 = @truncate(hdr & 0xFFFF);
                if (wc == 0) break;
                const ie = pos + wc;
                if (ie > current_words.len) break;
                if (opcode == 65 and wc >= 5) { // OpAccessChain
                    const ac_result = current_words[pos + 2];
                    const ac_base = current_words[pos + 3];
                    // Resolve transitive: if base is itself an AC result, follow chain
                    var resolved_base = ac_base;
                    while (ac_to_base.get(resolved_base)) |deeper| resolved_base = deeper;
                    try ac_to_base.put(alloc, ac_result, resolved_base);
                }
                pos = ie;
            }

            // Build result_id -> position map for quick replacement
            // Also build a replacement map: old_id -> new_id
            var replacements = std.AutoHashMapUnmanaged(u32, u32).empty;
            defer replacements.deinit(alloc);

            // First pass: find forwarding opportunities
            // Track stores per block (cleared at OpLabel)
            var last_store = std.AutoHashMapUnmanaged(u32, u32).empty; // ptr -> val
            defer last_store.deinit(alloc);

            pos = 5;
            while (pos < current_words.len) {
                const hdr = current_words[pos];
                const wc: u32 = hdr >> 16;
                const opcode: u16 = @truncate(hdr & 0xFFFF);
                if (wc == 0) break;
                const inst_end = pos + wc;
                if (inst_end > current_words.len) break;

                switch (opcode) {
                    // OpLabel: clear per-block state
                    248 => { // OpLabel
                        last_store.clearRetainingCapacity();
                    },
                    // OpStore: track ptr -> val
                    62 => { // OpStore: ptr, obj, [mem-access]
                        if (wc >= 3) {
                            const ptr = current_words[pos + 1];
                            const val = current_words[pos + 2];
                            last_store.put(alloc, ptr, val) catch {};
                            // If storing to an AC result, invalidate forwarding for the base variable
                            if (ac_to_base.get(ptr)) |base_var| {
                                _ = last_store.remove(base_var);
                            }
                        }
                    },
                    // OpLoad: check if we have a forwarded value
                    61 => { // OpLoad: result_type, result_id, ptr
                        if (wc >= 4) {
                            const load_result = current_words[pos + 2];
                            const ptr = current_words[pos + 3];
                            if (last_store.get(ptr)) |val| {
                                // Forward: replace load_result -> val
                                if (load_result >= 1 and load_result < fwd_bound) {
                                    replacements.put(alloc, load_result, val) catch {};
                                }
                            }
                        }
                    },
                    // OpCopyMemory: clear store tracking for dst
                    37 => { // OpCopyMemory: dst, src
                        if (wc >= 3) {
                            const dst = current_words[pos + 1];
                            // Don't forward from dst anymore
                            _ = last_store.remove(dst);
                        }
                    },
                    else => {},
                }
                pos = inst_end;
            }

            if (replacements.count() > 0) {
                // Apply replacements and remove dead loads
                var fwd_result = std.ArrayList(u32).initCapacity(alloc, current_words.len) catch return current_words;
                fwd_result.appendSliceAssumeCapacity(current_words[0..5]);

                pos = 5;
                while (pos < current_words.len) {
                    const hdr = current_words[pos];
                    const wc: u32 = hdr >> 16;
                    const opcode: u16 = @truncate(hdr & 0xFFFF);
                    if (wc == 0) break;
                    const inst_end = pos + wc;
                    if (inst_end > current_words.len) break;

                    // Skip OpLoad that was forwarded (it's dead)
                    if (opcode == 61 and wc >= 4) { // OpLoad
                        const load_result = current_words[pos + 2];
                        if (replacements.contains(load_result)) {
                            pos = inst_end;
                            continue;
                        }
                    }

                    // Apply replacements to all ID operands
                    const info = compact_ids.getOpInfo(opcode) orelse {
                        fwd_result.appendSliceAssumeCapacity(current_words[pos..inst_end]);
                        pos = inst_end;
                        continue;
                    };

                    try fwd_result.append(alloc, hdr); // header
                    var wi: u32 = pos + 1;

                    // Handle fixed operands (result_type, result_id)
                    switch (info.fixed) {
                        1 => {
                            if (wi < inst_end) {
                                const w = current_words[wi];
                                try fwd_result.append(alloc, replacements.get(w) orelse w);
                                wi += 1;
                            }
                        },
                        2 => {
                            if (wi < inst_end) {
                                const w = current_words[wi];
                                try fwd_result.append(alloc, replacements.get(w) orelse w);
                                wi += 1;
                            }
                            if (wi < inst_end) {
                                try fwd_result.append(alloc, current_words[wi]); // result_id — never replace
                                wi += 1;
                            }
                        },
                        3 => {
                            if (wi < inst_end) {
                                try fwd_result.append(alloc, current_words[wi]); // result_id — never replace
                                wi += 1;
                            }
                        },
                        else => {},
                    }

                    // Handle variable operands
                    for (info.ops) |ch| {
                        if (wi >= inst_end) break;
                        switch (ch) {
                            'i' => {
                                const w = current_words[wi];
                                try fwd_result.append(alloc, replacements.get(w) orelse w);
                                wi += 1;
                            },
                            'l' => {
                                try fwd_result.append(alloc, current_words[wi]);
                                wi += 1;
                            },
                            'I' => {
                                while (wi < inst_end) : (wi += 1) {
                                    const w = current_words[wi];
                                    try fwd_result.append(alloc, replacements.get(w) orelse w);
                                }
                            },
                            'L' => { while (wi < inst_end) : (wi += 1) try fwd_result.append(alloc, current_words[wi]); },
                            's' => { while (wi < inst_end) : (wi += 1) try fwd_result.append(alloc, current_words[wi]); },
                            'M' => {
                                if (wi < inst_end) {
                                    try fwd_result.append(alloc, current_words[wi]); // image
                                    wi += 1;
                                }
                                while (wi < inst_end) : (wi += 1) {
                                    const w = current_words[wi];
                                    try fwd_result.append(alloc, replacements.get(w) orelse w);
                                }
                            },
                            'W' => {
                                // wi is at the first literal (after ii was processed)
                                // Read literal first, then target with replacement
                                while (wi + 1 < inst_end) {
                                    try fwd_result.append(alloc, current_words[wi]); // literal
                                    wi += 1;
                                    const w = current_words[wi];
                                    try fwd_result.append(alloc, replacements.get(w) orelse w); // target
                                    wi += 1;
                                }
                                if (wi < inst_end) {
                                    try fwd_result.append(alloc, current_words[wi]); // trailing literal
                                    wi += 1;
                                }
                            },
                            'E' => {
                                // Literal string + IDs
                                var in_string = true;
                                while (wi < inst_end and in_string) : (wi += 1) {
                                    try fwd_result.append(alloc, current_words[wi]);
                                    const w = current_words[wi];
                                    if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) in_string = false;
                                }
                                while (wi < inst_end) : (wi += 1) {
                                    const w = current_words[wi];
                                    try fwd_result.append(alloc, replacements.get(w) orelse w);
                                }
                            },
                            else => {
                                try fwd_result.append(alloc, current_words[wi]);
                                wi += 1;
                            },
                        }
                    }
                    // Append any remaining words
                    while (wi < inst_end) : (wi += 1) {
                        try fwd_result.append(alloc, current_words[wi]);
                    }
                    pos = inst_end;
                }

                const fwd_words = fwd_result.toOwnedSlice(alloc) catch return current_words;
                // Re-run DCE to clean up dead stores and cascading dead code
                const re_dce = deadCodeElim(alloc, fwd_words) catch return fwd_words;
                if (re_dce.ptr != fwd_words.ptr) alloc.free(fwd_words);
                if (current_words.ptr != words.ptr) alloc.free(current_words);
                return re_dce;
            }
        }
    }

    // Cross-block store-to-load forwarding from entry block
    // For function-local vars stored exactly once (in entry block, with no other stores anywhere),
    // replace all loads with the stored value. Safe because entry dominates all blocks.
    {
        const xb_bound = current_words[3];
        if (xb_bound > 1) {
            // Collect function-local vars (Function storage class only, not Private)
            var xb_func_vars = try std.DynamicBitSet.initEmpty(alloc, xb_bound);
            defer xb_func_vars.deinit();
            pos = 5;
            while (pos < current_words.len) {
                const hdr = current_words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
                if (wc == 0) break;
                if (opcode == 59 and wc >= 4 and current_words[pos + 3] == 7) {
                    const var_id = current_words[pos + 2];
                    if (var_id >= 1 and var_id < xb_bound) xb_func_vars.set(var_id);
                }
                pos += wc;
            }

            if (xb_func_vars.count() > 0) {
                // For each function-local var, count ALL stores and record the entry-block store value
                var xb_total_stores = std.AutoHashMapUnmanaged(u32, u32).empty; // var_id -> total store count
                defer xb_total_stores.deinit(alloc);
                var xb_entry_store_val = std.AutoHashMapUnmanaged(u32, u32).empty; // var_id -> value (only if 1 entry store)
                defer xb_entry_store_val.deinit(alloc);

                // Also check for unsafe uses (AccessChain, CopyMemory, ExtInst, FunctionCall)
                var xb_unsafe_vars = try std.DynamicBitSet.initEmpty(alloc, xb_bound);
                defer xb_unsafe_vars.deinit();

                var in_func = false;
                var first_label = true;
                var in_entry = false;
                pos = 5;
                while (pos < current_words.len) {
                    const hdr = current_words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
                    if (wc == 0) break;
                    const ie = pos + wc;

                    if (opcode == 54) { in_func = true; first_label = true; in_entry = false; }
                    if (opcode == 56) { in_func = false; in_entry = false; }
                    if (opcode == 248 and in_func) {
                        in_entry = first_label;
                        first_label = false;
                    }
                    if (opcode == 249 or opcode == 250 or opcode == 251) in_entry = false;

                    if (in_func) {
                        // Count ALL stores to func vars
                        if (opcode == 62 and wc >= 3) { // OpStore
                            const ptr = current_words[pos + 1];
                            const val = current_words[pos + 2];
                            if (ptr < xb_bound and xb_func_vars.isSet(ptr)) {
                                const entry = try xb_total_stores.getOrPutValue(alloc, ptr, 0);
                                entry.value_ptr.* += 1;
                                if (in_entry and entry.value_ptr.* == 1) {
                                    try xb_entry_store_val.put(alloc, ptr, val);
                                } else if (in_entry) {
                                    _ = xb_entry_store_val.remove(ptr); // multiple entry stores
                                }
                            }
                        }
                        // Check for AccessChain uses
                        if ((opcode == 65 or opcode == 66) and wc >= 5) {
                            const base = current_words[pos + 3];
                            if (base < xb_bound and xb_func_vars.isSet(base)) xb_unsafe_vars.set(base);
                        }
                        // CopyMemory
                        if (opcode == 63 and wc >= 3) {
                            const dst = current_words[pos + 1];
                            const src = current_words[pos + 2];
                            if (dst < xb_bound and xb_func_vars.isSet(dst)) xb_unsafe_vars.set(dst);
                            if (src < xb_bound and xb_func_vars.isSet(src)) xb_unsafe_vars.set(src);
                        }
                        // ExtInst
                        if (opcode == 12 and wc >= 6) {
                            var ei: u32 = pos + 5;
                            while (ei < ie) : (ei += 1) {
                                if (current_words[ei] < xb_bound and xb_func_vars.isSet(current_words[ei])) {
                                    xb_unsafe_vars.set(current_words[ei]);
                                }
                            }
                        }
                        // FunctionCall args (opcode 57): func args may be read/written
                        if (opcode == 57 and wc >= 5) {
                            var ai: u32 = pos + 4; // skip hdr, type, result, func_id
                            while (ai < ie) : (ai += 1) {
                                if (current_words[ai] < xb_bound and xb_func_vars.isSet(current_words[ai])) {
                                    xb_unsafe_vars.set(current_words[ai]);
                                }
                            }
                        }
                    }
                    pos = ie;
                }

                // Identify forwardable vars: exactly 1 total store, stored in entry, no unsafe uses
                var xb_var_to_value = std.AutoHashMapUnmanaged(u32, u32).empty;
                defer xb_var_to_value.deinit(alloc);

                var evi = xb_entry_store_val.iterator();
                while (evi.next()) |kv| {
                    const var_id = kv.key_ptr.*;
                    const total = xb_total_stores.get(var_id) orelse 0;
                    if (total == 1 and !xb_unsafe_vars.isSet(var_id)) {
                        try xb_var_to_value.put(alloc, var_id, kv.value_ptr.*);
                    }
                }

                if (xb_var_to_value.count() > 0) {
                    // Build load result -> forwarded value map
                    var xb_load_fwd = std.AutoHashMapUnmanaged(u32, u32).empty;
                    defer xb_load_fwd.deinit(alloc);
                    pos = 5;
                    while (pos < current_words.len) {
                        const hdr = current_words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
                        if (wc == 0) break;
                        if (opcode == 61 and wc >= 4) { // OpLoad
                            const ptr = current_words[pos + 3];
                            const result = current_words[pos + 2];
                            if (xb_var_to_value.get(ptr)) |val| {
                                try xb_load_fwd.put(alloc, result, val);
                            }
                        }
                        pos += wc;
                    }

                    if (xb_load_fwd.count() > 0) {
                        // Rewrite: skip dead vars, stores, and loads; replace load result uses
                        var xb_result = std.ArrayList(u32).initCapacity(alloc, current_words.len) catch return current_words;
                        xb_result.appendSliceAssumeCapacity(current_words[0..5]);

                        pos = 5;
                        while (pos < current_words.len) {
                            const hdr = current_words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
                            if (wc == 0) break;
                            const ie = pos + wc;

                            // Skip dead variable declarations
                            if (opcode == 59 and wc >= 3 and xb_var_to_value.contains(current_words[pos + 2])) {
                                pos = ie; continue;
                            }
                            // Skip stores to forwardable vars
                            if (opcode == 62 and wc >= 2 and xb_var_to_value.contains(current_words[pos + 1])) {
                                pos = ie; continue;
                            }
                            // Skip loads of forwardable vars
                            if (opcode == 61 and wc >= 4 and xb_load_fwd.contains(current_words[pos + 2])) {
                                pos = ie; continue;
                            }

                            // Apply replacements using getOpInfo
                            const info = compact_ids.getOpInfo(opcode) orelse {
                                xb_result.appendSlice(alloc, current_words[pos..ie]) catch return current_words;
                                pos = ie; continue;
                            };

                            try xb_result.append(alloc, hdr);
                            var wi: u32 = pos + 1;
                            switch (info.fixed) {
                                1 => { if (wi < ie) { try xb_result.append(alloc, xb_load_fwd.get(current_words[wi]) orelse current_words[wi]); wi += 1; } },
                                2 => {
                                    if (wi < ie) { try xb_result.append(alloc, xb_load_fwd.get(current_words[wi]) orelse current_words[wi]); wi += 1; }
                                    if (wi < ie) { try xb_result.append(alloc, current_words[wi]); wi += 1; }
                                },
                                3 => { if (wi < ie) { try xb_result.append(alloc, current_words[wi]); wi += 1; } },
                                else => {},
                            }
                            for (info.ops) |ch| {
                                if (wi >= ie) break;
                                switch (ch) {
                                    'i' => { try xb_result.append(alloc, xb_load_fwd.get(current_words[wi]) orelse current_words[wi]); wi += 1; },
                                    'l' => { try xb_result.append(alloc, current_words[wi]); wi += 1; },
                                    'I' => { while (wi < ie) : (wi += 1) try xb_result.append(alloc, xb_load_fwd.get(current_words[wi]) orelse current_words[wi]); },
                                    'L', 's' => { while (wi < ie) : (wi += 1) try xb_result.append(alloc, current_words[wi]); },
                                    'M' => { if (wi < ie) { try xb_result.append(alloc, current_words[wi]); wi += 1; } while (wi < ie) : (wi += 1) try xb_result.append(alloc, xb_load_fwd.get(current_words[wi]) orelse current_words[wi]); },
                                    'W' => { while (wi + 1 < ie) { try xb_result.append(alloc, current_words[wi]); wi += 1; try xb_result.append(alloc, xb_load_fwd.get(current_words[wi]) orelse current_words[wi]); wi += 1; } if (wi < ie) { try xb_result.append(alloc, current_words[wi]); wi += 1; } },
                                    'E' => { while (wi < ie) { const w = current_words[wi]; wi += 1; try xb_result.append(alloc, w); if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (wi < ie) : (wi += 1) try xb_result.append(alloc, xb_load_fwd.get(current_words[wi]) orelse current_words[wi]); },
                                    else => { try xb_result.append(alloc, current_words[wi]); wi += 1; },
                                }
                            }
                            while (wi < ie) : (wi += 1) try xb_result.append(alloc, current_words[wi]);
                            pos = ie;
                        }

                        if (xb_result.items.len < current_words.len) {
                            if (current_words.ptr != words.ptr) alloc.free(current_words);
                            const xb_words = xb_result.toOwnedSlice(alloc) catch return current_words;
                            const re_dce = deadCodeElim(alloc, xb_words) catch return xb_words;
                            if (re_dce.ptr != xb_words.ptr) alloc.free(xb_words);
                            return re_dce;
                        } else {
                            xb_result.deinit(alloc);
                        }
                    }
                }
            }
        }
    }

    return current_words;
}

/// Merge chained AccessChain instructions where the base is itself an AccessChain result
/// and the base AccessChain is only used once (by the current one).
pub fn mergeAccessChains(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Build result_id -> instruction position map for AccessChains
    const AC = struct { pos: u32, base_id: u32, indices_start: u32, indices_count: u32, result_id: u32 };
    var ac_map = std.AutoHashMapUnmanaged(u32, AC).empty; // result_id -> AC info
    defer ac_map.deinit(alloc);

    // First pass: find all AccessChains
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 65) { // OpAccessChain
            // Layout: result_type(1), result_id(1), base_id(1), indices...(rest)
            if (wc >= 5) {
                const result_id = words[pos + 2];
                const base_id = words[pos + 3];
                ac_map.put(alloc, result_id, .{
                    .pos = pos,
                    .base_id = base_id,
                    .indices_start = pos + 4,
                    .indices_count = wc - 4,
                    .result_id = result_id,
                }) catch {};
            }
        }
        pos += wc;
    }

    // Build reference count for AccessChain results
    var ref_count = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer ref_count.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        // Count references to AccessChain results (skip the definition itself)
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        const info = compact_ids.getOpInfo(opcode) orelse { pos += wc; continue; };
        var wi: u32 = pos + 1;
        switch (info.fixed) {
            1 => { if (wi < pos + wc) wi += 1; }, // skip result_type (not an AC result ref)
            2 => { if (wi < pos + wc) wi += 1; if (wi < pos + wc) wi += 1; }, // skip result_type + result
            3 => { if (wi < pos + wc) wi += 1; }, // skip result
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= pos + wc) break;
            switch (ch) {
                'i' => {
                    const w = words[wi];
                    if (ac_map.contains(w)) {
                        const entry = ref_count.getOrPutValue(alloc, w, 0) catch null;
                        if (entry != null) entry.?.value_ptr.* += 1;
                    }
                    wi += 1;
                },
                'I' => {
                    while (wi < pos + wc) : (wi += 1) {
                        const w = words[wi];
                        if (ac_map.contains(w)) {
                            const entry = ref_count.getOrPutValue(alloc, w, 0) catch null;
                            if (entry != null) entry.?.value_ptr.* += 1;
                        }
                    }
                },
                'l' => { wi += 1; },
                'L' => { wi = pos + wc; },
                's' => { wi = pos + wc; },
                'M' => { if (wi < pos + wc) { wi += 1; while (wi < pos + wc) : (wi += 1) { const w = words[wi]; if (ac_map.contains(w)) { const entry = ref_count.getOrPutValue(alloc, w, 0) catch null; if (entry != null) entry.?.value_ptr.* += 1; } } } },
                'W' => { while (wi + 1 < pos + wc) { wi += 1; const w = words[wi]; if (ac_map.contains(w)) { const entry = ref_count.getOrPutValue(alloc, w, 0) catch null; if (entry != null) entry.?.value_ptr.* += 1; } wi += 1; } if (wi < pos + wc) wi += 1; },
                else => { wi += 1; },
            }
        }
        pos += wc;
    }

    // Identify AC results whose ONLY users are other AccessChain instructions
    var all_ac_users = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer all_ac_users.deinit();
    // Initially mark all ACs as having all-AC users
    var ac_iter = ac_map.iterator();
    while (ac_iter.next()) |entry| {
        all_ac_users.set(entry.key_ptr.*);
    }
    // Unmark any AC that is referenced by a non-AC instruction
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (opcode != 65) { // Not an AccessChain
            const info = compact_ids.getOpInfo(opcode) orelse { pos += wc; continue; };
            var wi: u32 = pos + 1;
            switch (info.fixed) {
                1 => { if (wi < pos + wc) { if (wi < bound and all_ac_users.isSet(words[wi])) all_ac_users.unset(words[wi]); wi += 1; } },
                2 => { if (wi < pos + wc) wi += 1; if (wi < pos + wc) wi += 1; }, // skip result_type + result
                3 => { if (wi < pos + wc) wi += 1; }, // skip result
                else => {},
            }
            for (info.ops) |ch| {
                if (wi >= pos + wc) break;
                switch (ch) {
                    'i' => { if (wi < bound and words[wi] < bound and all_ac_users.isSet(words[wi])) all_ac_users.unset(words[wi]); wi += 1; },
                    'I' => { while (wi < pos + wc) : (wi += 1) { if (wi < bound and words[wi] < bound and all_ac_users.isSet(words[wi])) all_ac_users.unset(words[wi]); } },
                    'l' => { wi += 1; },
                    'L' => { wi = pos + wc; },
                    's' => { wi = pos + wc; },
                    'M' => { if (wi < pos + wc) { wi += 1; while (wi < pos + wc) : (wi += 1) { if (wi < bound and words[wi] < bound and all_ac_users.isSet(words[wi])) all_ac_users.unset(words[wi]); } } },
                    'W' => { while (wi + 1 < pos + wc) { wi += 1; if (wi < bound and words[wi] < bound and all_ac_users.isSet(words[wi])) all_ac_users.unset(words[wi]); wi += 1; } if (wi < pos + wc) wi += 1; },
                    else => { wi += 1; },
                }
            }
        }
        pos += wc;
    }

    // Second pass: merge AccessChains
    // For single-use bases: merge as before
    // For multi-use bases where ALL users are ACs: merge all users with the base
    var result = std.ArrayListUnmanaged(u32).empty;
    try result.appendSlice(alloc, words[0..5]); // copy header

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const inst_end = pos + wc;

        if (opcode == 65 and wc >= 5) { // OpAccessChain
            const ac_result_id = words[pos + 2];
            const base_id = words[pos + 3];

            // Try to merge with base AccessChain
            // Collect index groups from innermost to outermost
            var index_groups = std.ArrayListUnmanaged(struct { start: u32, count: u32 }).empty;
            defer index_groups.deinit(alloc);
            
            // Our own indices first (innermost)
            try index_groups.append(alloc, .{ .start = pos + 4, .count = wc - 4 });
            
            var current_base = base_id;
            while (ac_map.get(current_base)) |base_ac| {
                const refs = ref_count.get(current_base) orelse 0;
                // Merge if: single-use (refs==1) OR all users are ACs and this base hasn't been merged yet
                if (refs == 1) {
                    try index_groups.append(alloc, .{ .start = base_ac.indices_start, .count = base_ac.indices_count });
                    current_base = base_ac.base_id;
                } else if (refs > 1 and current_base < bound and all_ac_users.isSet(current_base)) {
                    // Multi-use base where all users are ACs — safe to merge
                    try index_groups.append(alloc, .{ .start = base_ac.indices_start, .count = base_ac.indices_count });
                    current_base = base_ac.base_id;
                } else {
                    break;
                }
            }

            if (index_groups.items.len > 1) {
                // Merge: emit indices from outermost (last in list) to innermost (first in list)
                var total_indices: u32 = 0;
                for (index_groups.items) |g| total_indices += g.count;
                const new_wc: u32 = 4 + total_indices;
                const new_hdr = (new_wc << 16) | 65;
                try result.append(alloc, new_hdr);
                try result.append(alloc, words[pos + 1]); // result_type
                try result.append(alloc, ac_result_id); // result_id
                try result.append(alloc, current_base); // merged base
                // Emit from outermost to innermost
                var gi: usize = index_groups.items.len;
                while (gi > 0) {
                    gi -= 1;
                    const g = index_groups.items[gi];
                    for (g.start..g.start + g.count) |j| {
                        try result.append(alloc, words[j]);
                    }
                }
                pos = inst_end;
                continue;
            }
        }

        try result.appendSlice(alloc, words[pos..inst_end]);
        pos = inst_end;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }

    // Update bound (may be the same or lower after DCE runs)
    return result.toOwnedSlice(alloc);
}

/// Ensure no function's ENTRY block is a branch target. A loop whose header is
/// the very first statement of a function (no local-var inits / preamble before
/// it — e.g. `int f(int lo,int hi){ while(lo<=hi){...} }`) makes the loop header
/// the function's entry block, and the loop back-edge then branches to it.
/// SPIR-V forbids the entry block of a function from being the target of any
/// branch (spirv-val: "First block '%N' of function is targeted by block '%M'").
/// glslpp's `deadLoopElim` used to mask this by deleting such loops; now that
/// live early-return loops survive, this surfaces as invalid SPIR-V.
///
/// Fix: for each function whose entry block is a branch target, splice in a new
/// empty pre-header block as the new entry that unconditionally branches to the
/// old entry. Any OpVariable in the old entry is relocated into the pre-header so
/// it stays in the function's first block (a SPIR-V structural requirement).
/// Conservatively skipped if the entry block contains an OpPhi (a phi predecessor
/// rewrite would be required, which this simple splice does not perform — such a
/// shape does not arise for the var-based loop-as-entry case this targets).
pub fn ensureLoopPreheader(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    if (words.len < 5) return words;
    var bound = words[3];

    // Pass 1: locate each function's entry label and the span of its entry block,
    // and decide whether a pre-header is needed.
    const Edit = struct {
        entry_label: u32,
        new_label: u32,
        // word range [body_start, body_end) of the entry block's NON-variable
        // instructions that follow the entry OpLabel (terminator inclusive).
        var_words: []const u32, // OpVariable instructions to relocate (may be empty)
    };
    var edits = std.ArrayListUnmanaged(Edit).empty;
    defer edits.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const op: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (op != 54) { // not OpFunction
            pos = ie;
            continue;
        }
        // Skip OpFunction + OpFunctionParameter(s) to the entry OpLabel.
        var fp = ie;
        while (fp < words.len) {
            const pwc: u32 = words[fp] >> 16;
            const pop: u16 = @truncate(words[fp] & 0xFFFF);
            if (pwc == 0) break;
            if (pop == 55) { fp += pwc; continue; } // OpFunctionParameter
            break;
        }
        if (fp >= words.len) break;
        const lwc: u32 = words[fp] >> 16;
        const lop: u16 = @truncate(words[fp] & 0xFFFF);
        if (lop != 248 or lwc < 2) { pos = ie; continue; } // expected entry OpLabel
        const entry_label = words[fp + 1];

        // Find the end of the function (OpFunctionEnd) and whether the entry label
        // is a branch target anywhere in the function. Also detect an OpPhi in the
        // entry block (conservative skip).
        var func_end = fp;
        var is_target = false;
        var entry_has_phi = false;
        {
            // Walk the entry block first to spot an OpPhi.
            var bp = fp + lwc;
            while (bp < words.len) {
                const bwc: u32 = words[bp] >> 16;
                const bop: u16 = @truncate(words[bp] & 0xFFFF);
                if (bwc == 0) break;
                if (bop == 245) entry_has_phi = true; // OpPhi
                // Block terminators end the entry block.
                if (bop == 249 or bop == 250 or bop == 251 or bop == 253 or
                    bop == 254 or bop == 252 or bop == 255 or bop == 248)
                {
                    break;
                }
                bp += bwc;
            }
            // Walk to OpFunctionEnd scanning branch targets.
            var sp = fp;
            while (sp < words.len) {
                const swc: u32 = words[sp] >> 16;
                const sop: u16 = @truncate(words[sp] & 0xFFFF);
                if (swc == 0) break;
                if (sop == 56) { func_end = sp; break; } // OpFunctionEnd
                switch (sop) {
                    249 => if (swc >= 2 and words[sp + 1] == entry_label) { is_target = true; }, // OpBranch
                    250 => { // OpBranchConditional
                        if (swc >= 4 and (words[sp + 2] == entry_label or words[sp + 3] == entry_label)) is_target = true;
                    },
                    251 => { // OpSwitch: selector default [literal target]...
                        if (swc >= 3 and words[sp + 2] == entry_label) is_target = true;
                        var k: u32 = sp + 4;
                        while (k < sp + swc) : (k += 2) {
                            if (words[k] == entry_label) is_target = true;
                        }
                    },
                    else => {},
                }
                sp += swc;
            }
        }

        if (is_target and !entry_has_phi) {
            // Collect OpVariable instructions in the entry block (to relocate).
            var var_list = std.ArrayListUnmanaged(u32).empty;
            var bp = fp + lwc;
            while (bp < words.len) {
                const bwc: u32 = words[bp] >> 16;
                const bop: u16 = @truncate(words[bp] & 0xFFFF);
                if (bwc == 0) break;
                if (bop == 248) break; // next block
                if (bop == 59) { // OpVariable
                    var_list.appendSlice(alloc, words[bp .. bp + bwc]) catch {};
                }
                // Stop at the block terminator.
                if (bop == 249 or bop == 250 or bop == 251 or bop == 253 or
                    bop == 254 or bop == 252 or bop == 255)
                {
                    break;
                }
                bp += bwc;
            }
            const var_words = var_list.toOwnedSlice(alloc) catch &.{};
            edits.append(alloc, .{ .entry_label = entry_label, .new_label = bound, .var_words = var_words }) catch {};
            bound += 1;
        }
        pos = ie;
    }

    if (edits.items.len == 0) return words;

    // Pass 2: rebuild. For each entry OpLabel that needs a pre-header, emit the new
    // pre-header (OpLabel + relocated OpVariables + OpBranch to old entry) BEFORE it,
    // and drop the relocated OpVariables from the old entry block.
    var result = std.ArrayList(u32).initCapacity(alloc, words.len + edits.items.len * 6) catch {
        for (edits.items) |e| if (e.var_words.len > 0) alloc.free(@constCast(e.var_words));
        return words;
    };
    result.appendSliceAssumeCapacity(words[0..5]);
    result.items[3] = bound;

    // Helper: find an edit for a given entry label.
    pos = 5;
    var active_drop: ?usize = null; // index into edits whose entry block we're in (dropping its vars)
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const op: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) {
            result.appendSlice(alloc, words[pos..]) catch {};
            break;
        }
        const ie = pos + wc;
        if (ie > words.len) { result.appendSlice(alloc, words[pos..]) catch {}; break; }

        if (op == 248 and wc >= 2) { // OpLabel
            const lbl = words[pos + 1];
            active_drop = null;
            var matched: ?usize = null;
            for (edits.items, 0..) |e, idx| {
                if (e.entry_label == lbl) { matched = idx; break; }
            }
            if (matched) |idx| {
                const e = edits.items[idx];
                // Emit pre-header block.
                result.appendSlice(alloc, &.{ (2 << 16) | 248, e.new_label }) catch {}; // OpLabel new
                if (e.var_words.len > 0) result.appendSlice(alloc, e.var_words) catch {};
                result.appendSlice(alloc, &.{ (2 << 16) | 249, e.entry_label }) catch {}; // OpBranch entry
                // Emit the original entry OpLabel; mark that we must drop its vars.
                result.appendSlice(alloc, words[pos..ie]) catch {};
                active_drop = idx;
                pos = ie;
                continue;
            }
            result.appendSlice(alloc, words[pos..ie]) catch {};
            pos = ie;
            continue;
        }

        // Inside an entry block that gained a pre-header: drop relocated OpVariables.
        if (active_drop != null and op == 59) { // OpVariable
            pos = ie;
            continue;
        }
        // Any terminator/next-label clears the drop state (handled by the OpLabel case).
        if (active_drop != null and (op == 249 or op == 250 or op == 251 or
            op == 253 or op == 254 or op == 252 or op == 255))
        {
            active_drop = null;
        }

        result.appendSlice(alloc, words[pos..ie]) catch {};
        pos = ie;
    }

    for (edits.items) |e| if (e.var_words.len > 0) alloc.free(@constCast(e.var_words));
    return result.toOwnedSlice(alloc) catch words;
}

/// Dead loop elimination: remove loops whose bodies have no observable side effects
/// and whose computed values are never used after the loop.
pub fn deadLoopElim(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Collect function-local variable IDs
    var func_vars = std.AutoHashMapUnmanaged(u32, void).empty;
    defer func_vars.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 59 and wc >= 4) { // OpVariable Function
            if (words[pos + 3] == 7) func_vars.put(alloc, words[pos + 2], {}) catch {};
        }
        pos += wc;
    }

    // Find all OpLoopMerge instructions
    const LI = struct { header_pos: u32, merge_id: u32 };
    var loops = std.ArrayListUnmanaged(LI).empty;
    defer loops.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 246 and wc >= 3) loops.append(alloc, .{ .header_pos = pos, .merge_id = words[pos + 1] }) catch {};
        pos += wc;
    }
    if (loops.items.len == 0) return words;

    var dead_loops = std.DynamicBitSet.initEmpty(alloc, loops.items.len) catch return words;
    defer dead_loops.deinit();

    for (loops.items, 0..) |loop_info, li| {
        // Find header label
        var header_label_id: u32 = 0;
        { var sp: u32 = 5; while (sp < loop_info.header_pos) {
            const h = words[sp]; const w = h >> 16; if (w == 0) break;
            if ((@as(u16, @truncate(h & 0xFFFF)) == 248) and w >= 2) header_label_id = words[sp + 1];
            sp += w;
        }}
        if (header_label_id == 0) continue;

        // Phase 1: check for side effects (stores to non-func-local vars)
        // Build set of "safe pointers": func-local vars + AccessChains derived from them
        var safe_ptrs = std.DynamicBitSet.initEmpty(alloc, bound) catch continue;
        defer safe_ptrs.deinit();
        // Mark func-local vars as safe
        var fvi = func_vars.iterator();
        while (fvi.next()) |kv| {
            if (kv.key_ptr.* < bound) safe_ptrs.set(kv.key_ptr.*);
        }
        // Mark AccessChains whose base is safe (transitive)
        // Two passes to handle chains
        for (0..2) |_| {
            var sp: u32 = 5;
            while (sp < words.len) {
                const sh = words[sp]; const swc: u32 = sh >> 16; const sop: u16 = @truncate(sh & 0xFFFF);
                if (swc == 0) break;
                if (sop == 65 and swc >= 5) { // OpAccessChain
                    const base = words[sp + 3];
                    const result = words[sp + 2];
                    if (base < bound and safe_ptrs.isSet(base) and result < bound) {
                        safe_ptrs.set(result);
                    }
                }
                sp += swc;
            }
        }

        var has_side_effects = false;
        var in_loop = false;
        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            if (opcode == 248 and wc >= 2) {
                const lbl = words[pos + 1];
                if (lbl == header_label_id) in_loop = true;
                if (lbl == loop_info.merge_id) in_loop = false;
            }
            if (in_loop and !has_side_effects) {
                if (opcode == 62 and wc >= 3) { // OpStore
                    if (!safe_ptrs.isSet(words[pos + 1])) has_side_effects = true;
                } else if (opcode == 252 or opcode == 253 or opcode == 254 or
                           opcode == 4416 or opcode == 5380) {
                    // Early function exit / fragment discard inside the loop is a
                    // CONTROL-FLOW side effect: OpKill (252), OpReturn (253),
                    // OpReturnValue (254), OpTerminateInvocation (4416),
                    // OpDemoteToHelperInvocation (5380). The loop conditionally
                    // returns (or discards) before its merge, so its iterations
                    // ARE observable — deleting it is silent-wrong (e.g. a search
                    // loop whose hit returns early would collapse to its post-loop
                    // fallthrough value). Keep the loop.
                    has_side_effects = true;
                } else if (opcode == 63 or opcode == 234 or opcode == 235 or
                           (opcode >= 57 and opcode <= 60) or
                           (opcode >= 68 and opcode <= 76) or opcode == 99 or
                           opcode == 218 or opcode == 219) { // OpEmitVertex, OpEndPrimitive
                    has_side_effects = true;
                }
            }
            pos += wc;
        }
        if (has_side_effects) continue;

        // Phase 2: collect all result IDs defined in the loop body
        var loop_defined = std.DynamicBitSet.initEmpty(alloc, bound) catch continue;
        defer loop_defined.deinit();
        in_loop = false;
        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            if (opcode == 248 and wc >= 2) {
                const lbl = words[pos + 1];
                if (lbl == header_label_id) in_loop = true;
                if (lbl == loop_info.merge_id) in_loop = false;
            }
            if (in_loop) {
                // Find result ID for this instruction
                const info = compact_ids.getOpInfo(opcode) orelse { pos += wc; continue; };
                var result_id: u32 = 0;
                switch (info.fixed) {
                    2 => { if (wc >= 3) result_id = words[pos + 2]; },
                    3 => { if (wc >= 2) result_id = words[pos + 1]; },
                    else => {},
                }
                if (result_id > 0 and result_id < bound) loop_defined.set(result_id);
                // Also mark labels as defined in the loop
                if (opcode == 248 and wc >= 2) {
                    const lbl = words[pos + 1];
                    if (lbl > 0 and lbl < bound) loop_defined.set(lbl);
                }
            }
            pos += wc;
        }

        // Phase 3: check if any loop-defined value is referenced after the merge block
        var value_escapes = false;
        var past_merge = false;
        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            if (opcode == 248 and wc >= 2) {
                if (words[pos + 1] == loop_info.merge_id) past_merge = true;
            }
            if (past_merge and !value_escapes) {
                // Check all operand IDs for references to loop-defined values
                const info = compact_ids.getOpInfo(opcode) orelse { pos += wc; continue; };
                var wi: u32 = pos + 1;
                switch (info.fixed) {
                    1 => { if (wi < pos + wc) { if (words[wi] < bound and loop_defined.isSet(words[wi])) value_escapes = true; wi += 1; } },
                    2 => { if (wi < pos + wc) { if (words[wi] < bound and loop_defined.isSet(words[wi])) value_escapes = true; wi += 1; } if (wi < pos + wc) wi += 1; },
                    3 => { if (wi < pos + wc) wi += 1; }, // skip result
                    else => {},
                }
                for (info.ops) |ch| {
                    if (wi >= pos + wc) break;
                    switch (ch) {
                        'i' => { if (words[wi] < bound and loop_defined.isSet(words[wi])) value_escapes = true; wi += 1; },
                        'I' => { while (wi < pos + wc) : (wi += 1) { if (words[wi] < bound and loop_defined.isSet(words[wi])) value_escapes = true; } },
                        'M' => { if (wi < pos + wc) wi += 1; while (wi < pos + wc) : (wi += 1) { if (words[wi] < bound and loop_defined.isSet(words[wi])) value_escapes = true; } },
                        'W' => { while (wi + 1 < pos + wc) { wi += 1; if (words[wi] < bound and loop_defined.isSet(words[wi])) value_escapes = true; wi += 1; } if (wi < pos + wc) wi += 1; },
                        'E' => { while (wi < pos + wc) { const w = words[wi]; wi += 1; if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (wi < pos + wc) : (wi += 1) { if (words[wi] < bound and loop_defined.isSet(words[wi])) value_escapes = true; } },
                        else => { wi += 1; },
                    }
                }
            }
            pos += wc;
        }

        if (!value_escapes) {
            dead_loops.set(li);
        }
    }

    // Phase 2.5: Check if function-local vars stored in the loop are loaded after merge.
    // This catches loops that accumulate into local vars which later flow to output.
    // Only applies to loops currently marked dead (no value_escapes from Phase 3).
    if (dead_loops.count() > 0) {
        var dl_it = dead_loops.iterator(.{});
        while (dl_it.next()) |li_raw| {
            const li: u32 = @intCast(li_raw);
            const loop_info = loops.items[li];

            // Find the header label for this loop
            var header_label_id: u32 = 0;
            { var sp: u32 = 5; while (sp < loop_info.header_pos) {
                const h = words[sp]; const w: u32 = h >> 16; if (w == 0) break;
                if ((@as(u16, @truncate(h & 0xFFFF)) == 248) and w >= 2) header_label_id = words[sp + 1];
                sp += w;
            }}
            if (header_label_id == 0) continue;

            // Collect func-local vars stored inside the loop
            var loop_stored_locals = std.DynamicBitSet.initEmpty(alloc, bound) catch continue;
            defer loop_stored_locals.deinit();

            // Check if the loop is "simple" (no nested loops or switches)
            // AC+Store tracking is only safe for simple loops to avoid
            // breaking switch/loop dominance invariants
            // Note: skip the loop's own OpLoopMerge by tracking if we've seen it
            var has_nested_struct = false;
            var saw_own_merge = false;
            var in_loop2 = false;
            pos = 5;
            while (pos < words.len) {
                const hdr2 = words[pos]; const wc2: u32 = hdr2 >> 16; const op2: u16 = @truncate(hdr2 & 0xFFFF);
                if (wc2 == 0) break;
                if (op2 == 248 and wc2 >= 2) {
                    const lbl = words[pos + 1];
                    if (lbl == header_label_id) in_loop2 = true;
                    if (lbl == loop_info.merge_id) in_loop2 = false;
                }
                if (in_loop2) {
                    if (op2 == 246 and !saw_own_merge) { // OpLoopMerge
                        saw_own_merge = true; // skip the loop's own merge
                    } else if (op2 == 246) {
                        has_nested_struct = true; // nested loop
                    }
                    if (op2 == 251) has_nested_struct = true; // OpSwitch
                    if (op2 == 62 and wc2 >= 3) { // OpStore
                        const store_target = words[pos + 1];
                        if (func_vars.contains(store_target)) {
                            if (store_target < bound) loop_stored_locals.set(store_target);
                        }
                    }
                }
                pos += wc2;
            }

            // For simple loops without nested struct, also track AC+Store to composite vars
            if (!has_nested_struct) {
                var ac_to_base_dl = std.AutoHashMapUnmanaged(u32, u32).empty;
                defer ac_to_base_dl.deinit(alloc);
                in_loop2 = false;
                pos = 5;
                while (pos < words.len) {
                    const hdr3 = words[pos]; const wc3: u32 = hdr3 >> 16; const op3: u16 = @truncate(hdr3 & 0xFFFF);
                    if (wc3 == 0) break;
                    if (op3 == 248 and wc3 >= 2) {
                        const lbl = words[pos + 1];
                        if (lbl == header_label_id) in_loop2 = true;
                        if (lbl == loop_info.merge_id) in_loop2 = false;
                    }
                    // Capture AccessChain→base mappings GLOBALLY, not just in-loop:
                    // mergeAccessChains often HOISTS a struct/array member's access
                    // chain (`%ac = OpAccessChain %a %0`) to BEFORE the loop, while
                    // the in-loop store writes through that same hoisted `%ac`.
                    // Gating capture on `in_loop2` missed the hoisted chain, so the
                    // store below didn't resolve to base `%a` and the accumulator
                    // var was never recorded — the loop was then wrongly eliminated
                    // (#220). The store check stays in-loop; only capture is global.
                    if (op3 == 65 and wc3 >= 4) { // OpAccessChain
                        const ac_result = words[pos + 2];
                        const ac_base = words[pos + 3];
                        if (ac_base > 0 and ac_base < bound and func_vars.contains(ac_base) and ac_result > 0 and ac_result < bound) {
                            ac_to_base_dl.put(alloc, ac_result, ac_base) catch {};
                        }
                    }
                    if (in_loop2 and op3 == 62 and wc3 >= 3) { // OpStore
                        const store_target = words[pos + 1];
                        if (ac_to_base_dl.get(store_target)) |base_var| {
                            if (base_var < bound) loop_stored_locals.set(base_var);
                        }
                    }
                    pos += wc3;
                }
            }

            if (loop_stored_locals.count() == 0) continue;

            // Map AccessChain result -> base func-local var, so a post-loop read
            // of a STRUCT/ARRAY MEMBER of a loop-stored local (`a.s`, encoded as
            // `OpAccessChain %a … ; OpLoad %ac`) is recognized as a load of that
            // local. Without this, the load check below only matched a DIRECT
            // `OpLoad %a` and wrongly eliminated a loop that accumulates into a
            // struct member (the member folded to its initial value — #220).
            // Symmetric to the store-side AC tracking (ac_to_base_dl) above.
            var ac_to_base_load = std.AutoHashMapUnmanaged(u32, u32).empty;
            defer ac_to_base_load.deinit(alloc);
            pos = 5;
            while (pos < words.len) {
                const hdr3 = words[pos]; const wc3: u32 = hdr3 >> 16; const op3: u16 = @truncate(hdr3 & 0xFFFF);
                if (wc3 == 0) break;
                if (op3 == 65 and wc3 >= 4) { // OpAccessChain: result, type, base, ...
                    const ac_result = words[pos + 2];
                    const ac_base = words[pos + 3];
                    if (ac_result > 0 and ac_result < bound and ac_base < bound) {
                        // Resolve a base that is itself an AccessChain (nested
                        // member, e.g. `a.b.c`) to the underlying func-local.
                        const root = ac_to_base_load.get(ac_base) orelse ac_base;
                        if (loop_stored_locals.isSet(root)) ac_to_base_load.put(alloc, ac_result, root) catch {};
                    }
                }
                pos += wc3;
            }

            // Check if any of these vars are loaded after the merge label
            var local_value_escapes = false;
            var past_merge2 = false;
            pos = 5;
            while (pos < words.len) {
                const hdr2 = words[pos]; const wc2: u32 = hdr2 >> 16; const op2: u16 = @truncate(hdr2 & 0xFFFF);
                if (wc2 == 0) break;
                if (op2 == 248 and wc2 >= 2) {
                    if (words[pos + 1] == loop_info.merge_id) past_merge2 = true;
                }
                if (past_merge2 and !local_value_escapes) {
                    // Check OpLoad from a loop-stored-local — either directly, or
                    // via an AccessChain into one (a struct/array member read).
                    if (op2 == 61 and wc2 >= 4) { // OpLoad
                        const load_ptr = words[pos + 3];
                        if (load_ptr < bound and
                            (loop_stored_locals.isSet(load_ptr) or ac_to_base_load.contains(load_ptr)))
                        {
                            local_value_escapes = true;
                        }
                    }
                }
                pos += wc2;
            }

            if (local_value_escapes) dead_loops.unset(li);
        }
    }

    if (dead_loops.count() == 0) return words;

    // Filter inner loops contained within dead outer loops
    var dead_ranges = std.ArrayListUnmanaged(struct { header_label: u32, merge_label: u32, hdr_pos: u32, mrg_pos: u32 }).empty;
    defer dead_ranges.deinit(alloc);
    for (loops.items, 0..) |li, idx| {
        if (!dead_loops.isSet(idx)) continue;
        var ll: u32 = 0;
        { var sp: u32 = 5; while (sp < li.header_pos) {
            const h = words[sp]; const w = h >> 16; if (w == 0) break;
            if ((@as(u16, @truncate(h & 0xFFFF)) == 248) and w >= 2) ll = words[sp + 1];
            sp += w;
        }}
        if (ll == 0) continue;
        var mp: u32 = @intCast(words.len);
        { var sp: u32 = 5; while (sp < words.len) {
            const h = words[sp]; const w = h >> 16; if (w == 0) break;
            if ((@as(u16, @truncate(h & 0xFFFF)) == 248) and w >= 2 and words[sp + 1] == li.merge_id) { mp = sp; break; }
            sp += w;
        }}
        dead_ranges.append(alloc, .{ .header_label = ll, .merge_label = li.merge_id, .hdr_pos = li.header_pos, .mrg_pos = mp }) catch {};
    }

    var outermost = std.DynamicBitSet.initFull(alloc, dead_ranges.items.len) catch return words;
    defer outermost.deinit();
    for (dead_ranges.items, 0..) |dr, i| {
        for (dead_ranges.items, 0..) |dr2, j| {
            if (i != j and dr.hdr_pos > dr2.hdr_pos and dr.hdr_pos < dr2.mrg_pos) {
                outermost.unset(i); break;
            }
        }
    }

    var dead_header_labels = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer dead_header_labels.deinit(alloc);
    for (dead_ranges.items, 0..) |dr, idx| {
        if (outermost.isSet(idx)) dead_header_labels.put(alloc, dr.header_label, dr.merge_label) catch {};
    }

    // Remove dead loop bodies: replace header with Label + OpBranch to merge, skip everything until merge
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);
    pos = 5;
    var in_dead_loop = false;
    var dead_merge_id: u32 = 0;
    var skip_block = false;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (opcode == 248 and wc >= 2) { // OpLabel
            const lbl = words[pos + 1];
            if (dead_header_labels.get(lbl)) |mid| {
                in_dead_loop = true; dead_merge_id = mid; skip_block = true;
                result.appendSlice(alloc, words[pos..ie]) catch return words;
                result.append(alloc, (2 << 16) | 249) catch return words; // OpBranch
                result.append(alloc, mid) catch return words;
                pos = ie; continue;
            }
            if (in_dead_loop and lbl == dead_merge_id) {
                in_dead_loop = false; skip_block = false;
                result.appendSlice(alloc, words[pos..ie]) catch return words;
                pos = ie; continue;
            }
        }
        if (in_dead_loop or skip_block) { pos = ie; continue; }
        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }
    if (result.items.len == words.len) { result.deinit(alloc); return words; }

    // Phase 4.5: Fix OpPhi instructions that reference labels inside eliminated loops
    // When a dead loop is removed, its labels are gone but OpPhi entries may still reference them.
    var removed_labels = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer removed_labels.deinit();
    for (dead_ranges.items, 0..) |dr, idx| {
        if (!outermost.isSet(idx)) continue;
        var rp: u32 = dr.hdr_pos;
        while (rp < words.len) {
            const rh = words[rp]; const rwc: u32 = rh >> 16; const rop: u16 = @truncate(rh & 0xFFFF);
            if (rwc == 0) break;
            const rie = rp + rwc;
            if (rie > words.len) break;
            if (rop == 248 and rwc >= 2) {
                const lbl = words[rp + 1];
                if (lbl < bound) removed_labels.set(lbl);
            }
            if (rop == 248 and rwc >= 2 and words[rp + 1] == dr.merge_label) break;
            rp = rie;
        }
    }
    if (removed_labels.count() > 0) {
        var fixed = std.ArrayList(u32).initCapacity(alloc, result.items.len) catch return words;
        fixed.appendSliceAssumeCapacity(result.items[0..5]);
        var fp: u32 = 5;
        while (fp < result.items.len) {
            const fh = result.items[fp]; const fwc: u32 = fh >> 16; const fop: u16 = @truncate(fh & 0xFFFF);
            if (fwc == 0) break;
            const fie = fp + fwc;
            if (fie > result.items.len) break;
            if (fop == 245 and fwc >= 5) {
                const phi_type = result.items[fp + 1];
                const phi_result = result.items[fp + 2];
                var phi_buf = std.ArrayListUnmanaged(u32).initCapacity(alloc, fwc) catch {
                    fixed.appendSlice(alloc, result.items[fp..fie]) catch {};
                    fp = fie; continue;
                };
                defer phi_buf.deinit(alloc);
                phi_buf.appendAssumeCapacity(phi_type);
                phi_buf.appendAssumeCapacity(phi_result);
                var pi: u32 = fp + 3;
                while (pi + 1 < fie) : (pi += 2) {
                    const val = result.items[pi];
                    const lbl = result.items[pi + 1];
                    if (lbl >= bound or !removed_labels.isSet(lbl)) {
                        phi_buf.appendAssumeCapacity(val);
                        phi_buf.appendAssumeCapacity(lbl);
                    }
                }
                if (phi_buf.items.len >= 5) {
                    const new_wc: u32 = @intCast(phi_buf.items.len);
                    fixed.append(alloc, (new_wc << 16) | 245) catch return words;
                    fixed.appendSlice(alloc, phi_buf.items[1..]) catch return words;
                }
            } else {
                fixed.appendSlice(alloc, result.items[fp..fie]) catch return words;
            }
            fp = fie;
        }
        result.deinit(alloc);
        result = fixed;
    }

    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Block merging: when block A ends with OpBranch %B and B has exactly one predecessor (A),
/// merge B into A by appending B's instructions (minus the label) to A.
pub fn retargetEmptyBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build set of protected labels (referenced by OpPhi, LoopMerge, SelectionMerge, OpName)
    var protected = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer protected.deinit();
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        switch (opcode) {
            245 => { // OpPhi: type, result, (value, parent)+
                var pi: u32 = pos + 3;
                while (pi + 1 < ie) : (pi += 2) {
                    const p = words[pi + 1];
                    if (p >= 1 and p < bound) protected.set(p);
                }
            },
            246 => { // OpLoopMerge: merge, continue, control
                if (words[pos + 1] >= 1 and words[pos + 1] < bound) protected.set(words[pos + 1]);
                if (wc >= 4 and words[pos + 2] >= 1 and words[pos + 2] < bound) protected.set(words[pos + 2]);
            },
            247 => { // OpSelectionMerge: merge, control
                if (words[pos + 1] >= 1 and words[pos + 1] < bound) protected.set(words[pos + 1]);
            },
            5 => { // OpName: target may be a label
                if (words[pos + 1] >= 1 and words[pos + 1] < bound) protected.set(words[pos + 1]);
            },
            else => {},
        }
        pos = ie;
    }

    // Phase 2: Find empty passthrough blocks (OpLabel + OpBranch only, not protected)
    var empty_targets = std.AutoHashMapUnmanaged(u32, u32).empty; // label -> branch target
    defer empty_targets.deinit(alloc);

    pos = 5;
    var cur_label: u32 = 0;
    var inst_count: u32 = 0;
    var has_branch: bool = false;
    var branch_target: u32 = 0;

    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 248 and wc >= 2) { // OpLabel
            if (cur_label != 0 and inst_count == 2 and has_branch) {
                if (!protected.isSet(cur_label)) {
                    empty_targets.put(alloc, cur_label, branch_target) catch {};
                }
            }
            cur_label = words[pos + 1];
            inst_count = 1;
            has_branch = false;
            branch_target = 0;
        } else if (opcode == 56) { // OpFunctionEnd
            if (cur_label != 0 and inst_count == 2 and has_branch) {
                if (!protected.isSet(cur_label)) {
                    empty_targets.put(alloc, cur_label, branch_target) catch {};
                }
            }
            cur_label = 0;
        } else if (cur_label != 0) {
            inst_count += 1;
            if (opcode == 249 and wc >= 2) {
                has_branch = true;
                branch_target = words[pos + 1];
            }
            if (opcode == 253 or opcode == 254 or opcode == 255) {
                has_branch = false;
            }
        }
        pos = ie;
    }
    if (cur_label != 0 and inst_count == 2 and has_branch) {
        if (!protected.isSet(cur_label)) {
            empty_targets.put(alloc, cur_label, branch_target) catch {};
        }
    }

    // Resolve chains
    var changed = true;
    while (changed) {
        changed = false;
        var it = empty_targets.iterator();
        while (it.next()) |entry| {
            if (empty_targets.get(entry.value_ptr.*)) |ult| {
                if (entry.value_ptr.* != ult) {
                    entry.value_ptr.* = ult;
                    changed = true;
                }
            }
        }
    }

    if (empty_targets.count() == 0) return words;

    // Phase 3: Rewrite � retarget branches, skip empty blocks
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    var to_remove = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer to_remove.deinit();
    var ki = empty_targets.keyIterator();
    while (ki.next()) |k| to_remove.set(k.*);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 248 and wc >= 2) { // OpLabel
            const lid = words[pos + 1];
            if (to_remove.isSet(lid)) {
                // Skip label + following OpBranch
                pos = ie;
                if (pos < words.len) {
                    const h2 = words[pos]; const w2 = h2 >> 16; const o2: u16 = @truncate(h2 & 0xFFFF);
                    if (o2 == 249) pos += w2;
                }
                continue;
            }
        }

        // Retarget OpBranch
        if (opcode == 249 and wc >= 2) {
            const t = empty_targets.get(words[pos + 1]) orelse words[pos + 1];
            result.append(alloc, hdr) catch return words;
            result.append(alloc, t) catch return words;
            pos = ie;
            continue;
        }
        // Retarget OpBranchConditional
        if (opcode == 250 and wc >= 4) {
            result.appendSlice(alloc, words[pos..pos+2]) catch return words; // header + condition
            result.append(alloc, empty_targets.get(words[pos+2]) orelse words[pos+2]) catch return words;
            result.append(alloc, empty_targets.get(words[pos+3]) orelse words[pos+3]) catch return words;
            if (wc > 4) result.appendSlice(alloc, words[pos+4..ie]) catch return words;
            pos = ie;
            continue;
        }
        // Retarget OpSwitch (opcode 251)
        if (opcode == 251 and wc >= 3) {
            result.appendSlice(alloc, words[pos..pos+2]) catch return words; // header + selector
            result.append(alloc, empty_targets.get(words[pos+2]) orelse words[pos+2]) catch return words; // default
            var si: u32 = pos + 3;
            while (si + 1 < ie) : (si += 2) {
                result.append(alloc, words[si]) catch return words; // literal
                result.append(alloc, empty_targets.get(words[si+1]) orelse words[si+1]) catch return words;
            }
            pos = ie;
            continue;
        }

        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    return result.toOwnedSlice(alloc) catch return words;
}


pub fn mergeBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Pass 1: Build label -> position map and count predecessors
    var label_pos = std.AutoHashMapUnmanaged(u32, u32).empty; // label_id -> pos of OpLabel
    defer label_pos.deinit(alloc);
    var predecessors = std.AutoHashMapUnmanaged(u32, u32).empty; // label_id -> count
    defer predecessors.deinit(alloc);
    var branch_target = std.AutoHashMapUnmanaged(u32, u32).empty; // label_id -> branch target (only for OpBranch)
    defer branch_target.deinit(alloc);

    // Also track which labels are function entry points (first label in each function)
    var func_entries = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer func_entries.deinit();

    var pos: u32 = 5;
    var current_label: u32 = 0;
    var in_function = false;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;

        if (opcode == 54 and wc >= 3) { // OpFunction
            in_function = true;
            current_label = 0;
        }
        if (opcode == 56 and wc >= 1) { // OpFunctionEnd
            in_function = false;
            current_label = 0;
        }

        if (opcode == 248 and wc >= 2) { // OpLabel
            current_label = words[pos + 1];
            label_pos.put(alloc, current_label, pos) catch {};
            if (in_function and !func_entries.isSet(current_label)) {
                // First label in a function is tracked below
            }
        }

        if (opcode == 249 and wc >= 2) { // OpBranch
            const target = words[pos + 1];
            if (current_label != 0) {
                branch_target.put(alloc, current_label, target) catch {};
            }
            const entry = predecessors.getOrPutValue(alloc, target, 0) catch null;
            if (entry) |e| e.value_ptr.* += 1;
        }

        if (opcode == 250 and wc >= 4) { // OpBranchConditional
            const t = words[pos + 2];
            const f = words[pos + 3];
            const et = predecessors.getOrPutValue(alloc, t, 0) catch null;
            if (et) |e| e.value_ptr.* += 1;
            const ef = predecessors.getOrPutValue(alloc, f, 0) catch null;
            if (ef) |e| e.value_ptr.* += 1;
        }

        if (opcode == 251 and wc >= 3) { // OpSwitch
            const default = words[pos + 2];
            const ed = predecessors.getOrPutValue(alloc, default, 0) catch null;
            if (ed) |e| e.value_ptr.* += 1;
            var si: u32 = 3;
            while (si + 1 < wc) : (si += 2) {
                const st = words[pos + si + 1];
                const est = predecessors.getOrPutValue(alloc, st, 0) catch null;
                if (est) |e| e.value_ptr.* += 1;
            }
        }

        pos += wc;
    }

    // Pass 2: Find mergeable blocks
    // Block B is mergeable if:
    // 1. Exactly one predecessor (A)
    // 2. A branches unconditionally to B (OpBranch)
    // 3. B is not a function entry point
    // 4. B is not a loop merge target or continue target

    // Collect loop merge/continue targets AND selection merge targets
    var merge_targets = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer merge_targets.deinit();
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 246 and wc >= 3) { // OpLoopMerge
            if (words[pos + 1] < bound) merge_targets.set(words[pos + 1]); // merge
            if (words[pos + 2] < bound) merge_targets.set(words[pos + 2]); // continue
        }
        if (opcode == 247 and wc >= 2) { // OpSelectionMerge
            if (words[pos + 1] < bound) merge_targets.set(words[pos + 1]); // merge
        }
        pos += wc;
    }

    // Find first label in each function (entry point)
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 54) { // OpFunction
            // Scan to first OpLabel
            var fp = pos + wc;
            while (fp < words.len) {
                const fh = words[fp];
                const fw: u32 = fh >> 16;
                const fo: u16 = @truncate(fh & 0xFFFF);
                if (fw == 0) break;
                if (fo == 248 and fw >= 2) { // OpLabel
                    func_entries.set(words[fp + 1]);
                    break;
                }
                if (fo == 56) break; // OpFunctionEnd with no body
                fp += fw;
            }
        }
        pos += wc;
    }

    // Build set of labels whose blocks contain structured control flow (LoopMerge/SelectionMerge)
    // We can't merge the successor of these blocks
    var structured_labels = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer structured_labels.deinit();
    pos = 5;
    current_label = 0;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 248 and wc >= 2) current_label = words[pos + 1];
        if ((opcode == 246 or opcode == 247) and current_label < bound) { // OpLoopMerge or OpSelectionMerge
            structured_labels.set(current_label);
        }
        pos += wc;
    }

    // Build set of mergeable labels
    var mergeable = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer mergeable.deinit();

    var bt_iter = branch_target.iterator();
    while (bt_iter.next()) |kv| {
        const from_label = kv.key_ptr.*;
        const to_label = kv.value_ptr.*;
        if (from_label == to_label) continue; // self-loop
        if (to_label >= bound) continue;
        if (func_entries.isSet(to_label)) continue; // function entry
        if (merge_targets.isSet(to_label)) continue; // loop/selection merge target
        if (structured_labels.isSet(from_label)) continue; // predecessor has structured control flow
        if (structured_labels.isSet(to_label)) continue; // target has structured control flow
        const preds = predecessors.get(to_label) orelse 0;
        if (preds == 1) {
            // Additional safety: only merge if the target block is "empty" (just label + branch)
            // Check that the target block has exactly 2 instructions: OpLabel and OpBranch
            const tpos = label_pos.get(to_label) orelse continue;
            // OpLabel at tpos, next instruction at tpos + (words[tpos] >> 16)
            const label_wc = words[tpos] >> 16;
            const next_pos = tpos + label_wc;
            if (next_pos >= words.len) continue;
            const next_hdr = words[next_pos];
            const next_wc: u32 = next_hdr >> 16;
            const next_opcode: u16 = @truncate(next_hdr & 0xFFFF);
            // Must be OpBranch (opcode 249)
            if (next_opcode != 249) continue;
            // After OpBranch, must be another OpLabel (next block) or OpFunctionEnd
            const after_pos = next_pos + next_wc;
            if (after_pos >= words.len) continue;
            const after_opcode: u16 = @truncate(words[after_pos] & 0xFFFF);
            if (after_opcode != 248 and after_opcode != 56) continue; // OpLabel or OpFunctionEnd
            mergeable.set(to_label);
        }
    }

    if (mergeable.count() == 0) return words;

    // Pass 3: Build new binary, merging blocks
    // When we see OpBranch %B where B is mergeable, skip the branch and
    // also skip B's OpLabel when we reach it (merging B's body into A)
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    // Track which labels to skip (they've been merged into their predecessor)
    // and collect the instruction ranges to append after each branch
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        // Check if this is a label that was merged into a predecessor
        if (opcode == 248 and wc >= 2) {
            const lbl = words[pos + 1];
            if (mergeable.isSet(lbl)) {
                // Skip this label — it was merged into predecessor
                pos = ie;
                continue;
            }
        }

        // Check if this is OpBranch to a mergeable block
        if (opcode == 249 and wc >= 2) { // OpBranch
            const target = words[pos + 1];
            if (mergeable.isSet(target)) {
                // Don't emit the branch — the target block's body will follow
                // directly (its label was skipped above)
                pos = ie;
                continue;
            }
        }

        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }

    // Re-run DCE to clean up dead labels/branches
    const nw = result.toOwnedSlice(alloc) catch return words;
    var dce_result = deadCodeElim(alloc, nw) catch return nw;
    if (dce_result.ptr != nw.ptr) alloc.free(nw);

    // Pass 4: Empty predecessor merging
    // Find blocks that are ONLY OpLabel + OpBranch and have a single-successor target.
    // If the target has only this one predecessor, merge the predecessor into the target
    // by removing the OpBranch and keeping the predecessor's label (renaming target).
    {
        const dce_bound = dce_result[3];
        if (dce_bound > 1) {
            // Rebuild label_pos and predecessors for the DCE'd output
            var lp2 = std.AutoHashMapUnmanaged(u32, u32).empty;
            defer lp2.deinit(alloc);
            var preds2 = std.AutoHashMapUnmanaged(u32, u32).empty;
            defer preds2.deinit(alloc);
            var bt2 = std.AutoHashMapUnmanaged(u32, u32).empty; // from_label -> to_label
            defer bt2.deinit(alloc);
            var func_entries2 = try std.DynamicBitSet.initEmpty(alloc, dce_bound);
            defer func_entries2.deinit();
            var structured2 = try std.DynamicBitSet.initEmpty(alloc, dce_bound);
            defer structured2.deinit();

            pos = 5;
            var in_func = false;
            var cur_label: u32 = 0;
            while (pos < dce_result.len) {
                const hdr2 = dce_result[pos]; const wc2: u32 = hdr2 >> 16; const op2: u16 = @truncate(hdr2 & 0xFFFF);
                if (wc2 == 0) break;
                if (op2 == 54) { in_func = true; cur_label = 0; }
                if (op2 == 56) { in_func = false; }
                if (op2 == 248 and wc2 >= 2 and in_func) {
                    const lid = dce_result[pos + 1];
                    if (lid < dce_bound) {
                        try lp2.put(alloc, lid, pos);
                        if (cur_label == 0) func_entries2.set(lid); // first label in function
                        // Count predecessors: just track via branch_target
                        cur_label = lid;
                    }
                }
                if (op2 == 249 and wc2 >= 2 and in_func and cur_label > 0) {
                    const target = dce_result[pos + 1];
                    if (target < dce_bound) {
                        try bt2.put(alloc, cur_label, target);
                        const entry = try preds2.getOrPutValue(alloc, target, 0);
                        entry.value_ptr.* += 1;
                    }
                }
                if (op2 == 250 and wc2 >= 4 and in_func and cur_label > 0) {
                    const t1 = dce_result[pos + 2]; const t2 = dce_result[pos + 3];
                    if (t1 < dce_bound) { const e = try preds2.getOrPutValue(alloc, t1, 0); e.value_ptr.* += 1; }
                    if (t2 < dce_bound) { const e = try preds2.getOrPutValue(alloc, t2, 0); e.value_ptr.* += 1; }
                    structured2.set(cur_label);
                }
                if (op2 == 251 and wc2 >= 3 and in_func and cur_label > 0) {
                    structured2.set(cur_label);
                    // Default + cases
                    const default = dce_result[pos + 1];
                    if (default < dce_bound) { const e = try preds2.getOrPutValue(alloc, default, 0); e.value_ptr.* += 1; }
                    var si: u32 = pos + 3;
                    while (si + 1 < pos + wc2) : (si += 2) {
                        const case_target = dce_result[si + 1];
                        if (case_target < dce_bound) { const e = try preds2.getOrPutValue(alloc, case_target, 0); e.value_ptr.* += 1; }
                    }
                }
                if (op2 == 246 or op2 == 247 or op2 == 254) structured2.set(cur_label);
                // Also track loop merge/continue targets (for protection)
                if (op2 == 246 and wc2 >= 4) { // OpLoopMerge
                    structured2.set(dce_result[pos + 1]); // merge target
                    if (dce_result[pos + 2] < dce_bound) structured2.set(dce_result[pos + 2]); // continue target
                }
                if (op2 == 247 and wc2 >= 3) { // OpSelectionMerge
                    structured2.set(dce_result[pos + 1]); // merge target
                }
                pos += wc2;
            }

            // Find mergeable empty predecessors
            var empty_preds = std.AutoHashMapUnmanaged(u32, u32).empty; // from_label -> to_label
            defer empty_preds.deinit(alloc);

            var bt_iter2 = bt2.iterator();
            while (bt_iter2.next()) |kv| {
                const from = kv.key_ptr.*;
                const to = kv.value_ptr.*;
                if (from == to) continue;
                // Don't skip function entries — they CAN be empty predecessors
                // that can merge into their single successor
                if (structured2.isSet(from)) continue;
                if (structured2.isSet(to)) continue;
                if (to >= dce_bound) continue;
                const to_preds = preds2.get(to) orelse 0;
                if (to_preds != 1) continue;
                // Check that from-block is empty (only Label + Branch)
                const fpos = lp2.get(from) orelse continue;
                const flabel_wc = dce_result[fpos] >> 16;
                const next_p = fpos + flabel_wc;
                if (next_p >= dce_result.len) continue;
                const next_hdr = dce_result[next_p];
                const next_wc = next_hdr >> 16;
                const next_op: u16 = @truncate(next_hdr & 0xFFFF);
                if (next_op != 249) continue; // must be OpBranch
                if (next_p + next_wc >= dce_result.len) continue;
                const after_op_hdr = dce_result[next_p + next_wc];
                const after_op: u16 = @truncate(after_op_hdr & 0xFFFF);
                if (after_op == 248 or after_op == 56) { // next block or function end
                    try empty_preds.put(alloc, from, to);
                }
            }

            if (empty_preds.count() > 0) {
                // Merge: when we encounter the target's OpLabel, replace it with the predecessor's label
                // When we encounter the predecessor's OpLabel + OpBranch, skip them entirely
                var r2 = std.ArrayList(u32).initCapacity(alloc, dce_result.len) catch return dce_result;
                r2.appendSliceAssumeCapacity(dce_result[0..5]);

                pos = 5;
                while (pos < dce_result.len) {
                    const hdr2 = dce_result[pos]; const wc2: u32 = hdr2 >> 16; const op2: u16 = @truncate(hdr2 & 0xFFFF);
                    if (wc2 == 0) break;
                    const ie2 = pos + wc2;

                    // Skip empty predecessor blocks entirely (label + branch)
                    if (op2 == 248 and wc2 >= 2 and empty_preds.contains(dce_result[pos + 1])) {
                        // Skip the label
                        // Also skip the following OpBranch
                        const next_p2 = pos + wc2;
                        if (next_p2 < dce_result.len) {
                            const next_hdr2 = dce_result[next_p2];
                            const next_op2: u16 = @truncate(next_hdr2 & 0xFFFF);
                            if (next_op2 == 249) {
                                pos = next_p2 + (next_hdr2 >> 16);
                                continue;
                            }
                        }
                        // Just skip the label, keep the branch (shouldn't happen)
                        pos = ie2;
                        continue;
                    }

                    // Replace target label with predecessor label
                    if (op2 == 248 and wc2 >= 2) {
                        const target_label = dce_result[pos + 1];
                        // Find which predecessor maps to this target
                        var ep_iter = empty_preds.iterator();
                        while (ep_iter.next()) |kv| {
                            if (kv.value_ptr.* == target_label) {
                                // Replace target label with predecessor label
                                try r2.append(alloc, hdr2);
                                try r2.append(alloc, kv.key_ptr.*);
                                pos = ie2;
                                break;
                            }
                        } else {
                            r2.appendSlice(alloc, dce_result[pos..ie2]) catch return dce_result;
                            pos = ie2;
                            continue;
                        }
                        continue;
                    }

                    r2.appendSlice(alloc, dce_result[pos..ie2]) catch return dce_result;
                    pos = ie2;
                }

                if (r2.items.len < dce_result.len) {
                    alloc.free(dce_result);
                    const r2_owned = r2.toOwnedSlice(alloc) catch {
                        r2.deinit(alloc);
                        return words; // fallback: return original input (dce_result was a derived copy)
                    };
                    const final_dce = deadCodeElim(alloc, r2_owned) catch return r2_owned;
                    if (final_dce.ptr != r2_owned.ptr) alloc.free(r2_owned);
                    return final_dce;
                } else {
                    r2.deinit(alloc);
                }
            }
        }
    }

    return dce_result;
}

/// Merge non-empty blocks: when block B has a single predecessor A that branches
/// unconditionally to B, and B has no OpPhi, no structured control flow, and is
/// not a merge/continue target, merge B into A. Saves 1 OpBranch + 1 OpLabel = 2 IDs.
pub fn mergeNonEmptyBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Build label -> position map
    var label_pos = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer label_pos.deinit(alloc);
    var predecessors = std.AutoHashMapUnmanaged(u32, u32).empty; // label -> predecessor count
    defer predecessors.deinit(alloc);
    var branch_from = std.AutoHashMapUnmanaged(u32, u32).empty; // to_label -> from_label (only OpBranch)
    defer branch_from.deinit(alloc);

    // Track blocks with structured CF, OpPhi, and merge targets
    var structured_blocks = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer structured_blocks.deinit();
    var phi_blocks = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer phi_blocks.deinit();
    var merge_targets = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer merge_targets.deinit();
    var func_entries = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer func_entries.deinit();

    var pos: u32 = 5;
    var current_label: u32 = 0;
    var in_function = false;
    var first_label_in_func = true;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        if (opcode == 54) { // OpFunction
            in_function = true;
            first_label_in_func = true;
            current_label = 0;
        }
        if (opcode == 56) { // OpFunctionEnd
            in_function = false;
            current_label = 0;
        }

        if (opcode == 248 and wc >= 2) { // OpLabel
            current_label = words[pos + 1];
            label_pos.put(alloc, current_label, pos) catch {};
            if (in_function and first_label_in_func and current_label < bound) {
                func_entries.set(current_label);
                first_label_in_func = false;
            }
        }

        if (opcode == 245 and current_label < bound) { // OpPhi
            phi_blocks.set(current_label);
        }
        if ((opcode == 246 or opcode == 247) and current_label < bound) { // OpLoopMerge or OpSelectionMerge
            structured_blocks.set(current_label);
            // Track merge targets
            if (opcode == 246 and wc >= 3) { // OpLoopMerge
                if (words[pos + 1] < bound) merge_targets.set(words[pos + 1]);
                if (words[pos + 2] < bound) merge_targets.set(words[pos + 2]);
            }
            if (opcode == 247 and wc >= 2) { // OpSelectionMerge
                if (words[pos + 1] < bound) merge_targets.set(words[pos + 1]);
            }
        }

        if (opcode == 249 and wc >= 2) { // OpBranch
            const target = words[pos + 1];
            if (current_label != 0) {
                branch_from.put(alloc, target, current_label) catch {};
            }
            const entry = predecessors.getOrPutValue(alloc, target, 0) catch null;
            if (entry) |e| e.value_ptr.* += 1;
        }
        if (opcode == 250 and wc >= 4) { // OpBranchConditional
            const t = words[pos + 2];
            const f = words[pos + 3];
            const et = predecessors.getOrPutValue(alloc, t, 0) catch null;
            if (et) |e| e.value_ptr.* += 1;
            const ef = predecessors.getOrPutValue(alloc, f, 0) catch null;
            if (ef) |e| e.value_ptr.* += 1;
        }
        if (opcode == 251 and wc >= 3) { // OpSwitch
            const default = words[pos + 2];
            const ed = predecessors.getOrPutValue(alloc, default, 0) catch null;
            if (ed) |e| e.value_ptr.* += 1;
            var si: u32 = 3;
            while (si + 1 < wc) : (si += 2) {
                const st = words[pos + si + 1];
                const est = predecessors.getOrPutValue(alloc, st, 0) catch null;
                if (est) |e| e.value_ptr.* += 1;
            }
        }

        pos = ie;
    }

    // Find mergeable labels
    var mergeable = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer mergeable.deinit();
    // Map: merged_label -> predecessor_label
    var merge_map = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer merge_map.deinit(alloc);

    var bf_iter = branch_from.iterator();
    while (bf_iter.next()) |kv| {
        const to_label = kv.key_ptr.*;
        const from_label = kv.value_ptr.*;
        if (from_label == to_label) continue; // self-loop
        if (to_label >= bound) continue;
        if (func_entries.isSet(to_label)) continue;
        if (merge_targets.isSet(to_label)) continue;
        if (structured_blocks.isSet(from_label)) continue;
        if (structured_blocks.isSet(to_label)) continue;
        if (phi_blocks.isSet(to_label)) continue;
        // Check single predecessor
        const pred_count = predecessors.get(to_label) orelse 0;
        if (pred_count != 1) continue;
        // Verify the single predecessor is from_label
        if (branch_from.get(to_label)) |from| {
            if (from != from_label) continue;
        } else continue;

        mergeable.set(to_label);
        merge_map.put(alloc, to_label, from_label) catch {};
    }

    if (mergeable.count() == 0) return words;

    // Build new binary
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    current_label = 0;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        // Track current label for the skip-branch check
        if (opcode == 248 and wc >= 2) {
            current_label = words[pos + 1];
        }

        // Skip OpLabel of mergeable blocks
        if (opcode == 248 and wc >= 2) {
            const lbl = words[pos + 1];
            if (mergeable.isSet(lbl)) {
                pos = ie;
                continue;
            }
        }

        // Skip OpBranch to mergeable blocks (the specific branch from the predecessor)
        if (opcode == 249 and wc >= 2) {
            const target = words[pos + 1];
            if (mergeable.isSet(target)) {
                const expected_from = merge_map.get(target) orelse target;
                if (current_label == expected_from) {
                    pos = ie;
                    continue;
                }
            }
        }

        // Replace merged labels in OpPhi (opcode 245)
        if (opcode == 245 and wc >= 3) {
            result.appendSlice(alloc, words[pos..(pos + 3)]) catch return words;
            var opi: u32 = 3;
            while (opi + 1 < wc) {
                const value = words[pos + opi];
                const parent = words[pos + opi + 1];
                const replacement = merge_map.get(parent) orelse parent;
                result.append(alloc, value) catch return words;
                result.append(alloc, replacement) catch return words;
                opi += 2;
            }
            pos = ie;
            continue;
        }

        // Update OpBranch targets
        if (opcode == 249 and wc >= 2) {
            const target = merge_map.get(words[pos + 1]) orelse words[pos + 1];
            result.append(alloc, words[pos]) catch return words;
            result.append(alloc, target) catch return words;
            pos = ie;
            continue;
        }

        // Update OpBranchConditional targets
        if (opcode == 250 and wc >= 4) {
            const cond = words[pos + 1];
            const t = merge_map.get(words[pos + 2]) orelse words[pos + 2];
            const f = merge_map.get(words[pos + 3]) orelse words[pos + 3];
            result.append(alloc, words[pos]) catch return words;
            result.append(alloc, cond) catch return words;
            result.append(alloc, t) catch return words;
            result.append(alloc, f) catch return words;
            if (wc > 4) result.appendSlice(alloc, words[(pos + 4)..ie]) catch return words;
            pos = ie;
            continue;
        }

        // Update OpSwitch targets
        if (opcode == 251 and wc >= 3) {
            result.append(alloc, words[pos]) catch return words;
            result.append(alloc, words[pos + 1]) catch return words; // selector
            const default = merge_map.get(words[pos + 2]) orelse words[pos + 2];
            result.append(alloc, default) catch return words;
            // Case literals are 32-bit (1 word each), followed by target (1 word)
            var si: u32 = 3;
            while (si + 1 < wc) : (si += 2) {
                result.append(alloc, words[pos + si]) catch return words; // literal
                const st = merge_map.get(words[pos + si + 1]) orelse words[pos + si + 1];
                result.append(alloc, st) catch return words; // target
            }
            pos = ie;
            continue;
        }

        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }

    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce_result = deadCodeElim(alloc, nw) catch return nw;
    if (dce_result.ptr != nw.ptr) alloc.free(nw);
    return dce_result;
}

/// Constant-fold OpSelect: when the condition is OpConstantTrue or OpConstantFalse,
/// replace the select with the appropriate operand.
pub fn foldSelect(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Find bool type and true/false constants
    var bool_type: u32 = 0;
    var true_id: u32 = 0;
    var false_id: u32 = 0;

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 20 and wc >= 2) bool_type = words[pos + 1];
        if (opcode == 41 and wc >= 3 and words[pos + 1] == bool_type) true_id = words[pos + 2];
        if (opcode == 42 and wc >= 3 and words[pos + 1] == bool_type) false_id = words[pos + 2];
        pos += wc;
    }

    if (true_id == 0 and false_id == 0) return words;

    // Build replacement map: select_result -> replacement value
    var replacements = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer replacements.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 169 and wc >= 6) {
            const result_id = words[pos + 2];
            const cond = words[pos + 3];
            if (cond == true_id) replacements.put(alloc, result_id, words[pos + 4]) catch {}
            else if (cond == false_id) replacements.put(alloc, result_id, words[pos + 5]) catch {};
        }
        pos += wc;
    }

    if (replacements.count() == 0) return words;

    // Rewrite: skip folded selects, replace operand references
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        if (opcode == 169 and wc >= 6 and replacements.contains(words[pos + 2])) { pos = ie; continue; }

        const info = compact_ids.getOpInfo(opcode) orelse {
            result.appendSlice(alloc, words[pos..ie]) catch return words;
            pos = ie; continue;
        };

        var wi: u32 = pos + 1;
        try result.append(alloc, hdr);
        switch (info.fixed) {
            1 => { if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; } },
            2 => {
                if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; }
                if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
            },
            3 => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; },
                'l' => { try result.append(alloc, words[wi]); wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                'L', 's' => { while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]); },
                'M' => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                'W' => { while (wi + 1 < ie) { try result.append(alloc, words[wi]); wi += 1; try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; } if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
                'E' => { while (wi < ie) { const w = words[wi]; wi += 1; try result.append(alloc, w); if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                else => { try result.append(alloc, words[wi]); wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]);
        pos = ie;
    }

    if (result.items.len == words.len) { result.deinit(alloc); return words; }
    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Returns true iff structs `id_a` and `id_b` carry identical debug names
/// (OpMemberName) and identical decorations (OpDecorate / OpMemberDecorate),
/// comparing the operands with the target id field removed so only id_a/id_b
/// differ. Callers use this AFTER confirming the member-type lists match.
///
/// This guards the dedup merge: two byte-identical interface blocks such as
/// `A { vec4 ca }` and `B { vec4 cb }` share member types but differ in their
/// OpMemberName strings (`ca` vs `cb`). Merging them would alias one block's
/// member names — and layout decorations — onto the other, so they are NOT
/// duplicates. Genuinely-redundant copies of the same type keep identical
/// names + decorations and still match here.
fn structDebugAndDecorMatch(alloc: std.mem.Allocator, words: []const u32, id_a: u32, id_b: u32) error{OutOfMemory}!bool {
    var sig_a = std.ArrayList(u32).empty;
    defer sig_a.deinit(alloc);
    var sig_b = std.ArrayList(u32).empty;
    defer sig_b.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        // OpMemberName=6, OpDecorate=71, OpMemberDecorate=72 all carry the
        // target id in words[pos + 1]. Append a normalized record (opcode +
        // word-count + every operand except the target id) in stream order.
        if ((opcode == 6 or opcode == 71 or opcode == 72) and wc >= 2) {
            const target = words[pos + 1];
            const buf: ?*std.ArrayList(u32) = if (target == id_a) &sig_a else if (target == id_b) &sig_b else null;
            if (buf) |b| {
                try b.append(alloc, opcode);
                try b.append(alloc, wc);
                var k = pos + 2;
                while (k < ie) : (k += 1) try b.append(alloc, words[k]);
            }
        }
        pos = ie;
    }

    if (sig_a.items.len != sig_b.items.len) return false;
    return std.mem.eql(u32, sig_a.items, sig_b.items);
}

/// Deduplicate struct types with identical member layouts.
/// Multiple OpTypeStruct with same member types AND identical member names +
/// decorations → remap to first one, remove duplicates. Structs that share a
/// member-type layout but differ in OpMemberName/decorations (distinct
/// interface blocks) are kept separate — see `structDebugAndDecorMatch`.
pub fn dedupStructTypes(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Collect struct types: map (member_type_0, member_type_1, ...) → first result_id
    // Use a simple approach: hash the member types, store in a HashMap
    var structs = std.AutoHashMapUnmanaged(u64, u32).empty; // hash -> first_id
    defer structs.deinit(alloc);

    // Also build a replacement map for duplicate struct ids
    var replacements = std.AutoHashMapUnmanaged(u32, u32).empty; // dup_id -> first_id
    defer replacements.deinit(alloc);

    // First pass: find duplicate struct types
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 30 and wc >= 2) { // OpTypeStruct
            const result_id = words[pos + 1];
            const members = words[pos + 2 .. pos + wc];
            
            // Compute hash of member types
            var h: u64 = @intCast(members.len);
            for (members) |mid| {
                h = h *% 33 +% @as(u64, mid);
            }
            
            if (structs.get(h)) |first_id| {
                // Verify it's actually the same layout (hash collision check)
                // Find the first struct's members to compare
                var verify_pos: u32 = 5;
                var first_members: []const u32 = &[_]u32{};
                while (verify_pos < words.len) {
                    const vhdr = words[verify_pos]; const vwc: u32 = vhdr >> 16; const vop: u16 = @truncate(vhdr & 0xFFFF);
                    if (vwc == 0) break;
                    if (vop == 30 and vwc >= 2 and words[verify_pos + 1] == first_id) {
                        first_members = words[verify_pos + 2 .. verify_pos + vwc];
                        break;
                    }
                    verify_pos += vwc;
                }
                if (members.len == first_members.len and std.mem.eql(u32, members, first_members)
                    and try structDebugAndDecorMatch(alloc, words, first_id, result_id)) {
                    // True duplicate — same member types, names, and decorations.
                    try replacements.put(alloc, result_id, first_id);
                } else {
                    // Hash collision, or same member types but distinct member
                    // names/decorations (e.g. two byte-identical interface
                    // blocks). Store separately so the names are preserved.
                    try structs.put(alloc, h ^ @as(u64, result_id) *% 0x9E3779B97F4A7C15, result_id);
                }
            } else {
                try structs.put(alloc, h, result_id);
            }
        }
        pos += wc;
    }

    if (replacements.count() == 0) return words;

    // Also remap: decorations targeting duplicate struct ids, Name entries, etc.
    // The replacement is straightforward: replace all references to dup_id with first_id
    // Then DCE will remove the dead OpTypeStruct

    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        // Skip the duplicate OpTypeStruct entirely
        if (opcode == 30 and wc >= 2 and replacements.contains(words[pos + 1])) {
            pos = ie;
            continue;
        }
        // Substitute target ID in decorations (OpDecorate=71, OpMemberDecorate=72)
        // Skip decorations on replaced IDs — the first ID already has identical decorations
        if (opcode == 71 and wc >= 3 and replacements.contains(words[pos + 1])) { // OpDecorate
            pos = ie;
            continue;
        }
        if (opcode == 72 and wc >= 4 and replacements.contains(words[pos + 1])) { // OpMemberDecorate
            pos = ie;
            continue;
        }

        const info = compact_ids.getOpInfo(opcode) orelse {
            result.appendSlice(alloc, words[pos..ie]) catch return words;
            pos = ie; continue;
        };

        var wi: u32 = pos + 1;
        try result.append(alloc, hdr);
        switch (info.fixed) {
            1 => { if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; } },
            2 => {
                if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; }
                if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
            },
            3 => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; },
                'l' => { try result.append(alloc, words[wi]); wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                'L', 's' => { while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]); },
                'M' => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                'W' => { while (wi + 1 < ie) { try result.append(alloc, words[wi]); wi += 1; try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; } if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
                'E' => { while (wi < ie) { const w = words[wi]; wi += 1; try result.append(alloc, w); if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                else => { try result.append(alloc, words[wi]); wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]);
        pos = ie;
    }

    if (result.items.len == words.len) { result.deinit(alloc); return words; }
    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Deduplicate OpTypeArray declarations with the same (element_type, length).
pub fn dedupArrayTypes(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    var arrays = std.AutoHashMapUnmanaged(u64, u32).empty; // hash -> first_id
    defer arrays.deinit(alloc);
    var replacements = std.AutoHashMapUnmanaged(u32, u32).empty; // dup_id -> first_id
    defer replacements.deinit(alloc);

    // Pre-scan ArrayStride decorations: an array type's identity includes its
    // stride. std140 and std430 give the SAME (element, length) array DIFFERENT
    // strides (e.g. float[2] → 16 vs 4), so two such arrays must NOT merge —
    // doing so would drop one stride, or (since the OpDecorate dedup keys on the
    // value) leave two conflicting ArrayStride decorations on one id.
    var strides = std.AutoHashMapUnmanaged(u32, u32).empty; // array id -> ArrayStride
    defer strides.deinit(alloc);
    {
        var sp: u32 = 5;
        while (sp < words.len) {
            const hdr = words[sp]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            // OpDecorate=71, ArrayStride=6: word1=target, word2=decoration, word3=value
            if (opcode == 71 and wc >= 4 and words[sp + 2] == 6) {
                strides.put(alloc, words[sp + 1], words[sp + 3]) catch {};
            }
            sp += wc;
        }
    }

    // First pass: find duplicate array types
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 28 and wc >= 4) { // OpTypeArray
            const result_id = words[pos + 1];
            const element_type = words[pos + 2];
            const length = words[pos + 3];
            var h: u64 = 0xA110CA7E0000001;
            h = h *% 33 +% @as(u64, element_type);
            h = h *% 33 +% @as(u64, length);
            // Fold in the ArrayStride (0 if undecorated) so arrays that need
            // different strides hash differently and are never merged.
            h = h *% 33 +% @as(u64, strides.get(result_id) orelse 0);
            if (arrays.get(h)) |first_id| {
                if (first_id != result_id) {
                    replacements.put(alloc, result_id, first_id) catch {};
                }
            } else {
                arrays.put(alloc, h, result_id) catch {};
            }
        }
        pos += wc;
    }

    if (replacements.count() == 0) return words;

    // Track seen decorations to skip duplicates caused by dedup
    var seen_decorations = std.AutoHashMapUnmanaged(u64, void).empty; // hash -> {}
    defer seen_decorations.deinit(alloc);

    // Second pass: skip duplicate arrays and replace references
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        // Skip duplicate OpTypeArray
        if (opcode == 28 and wc >= 4 and replacements.contains(words[pos + 1])) {
            pos = ie;
            continue;
        }

        // Deduplicate OpDecorate: skip if we've already seen this (target, decoration) pair
        if (opcode == 71 and wc >= 3) { // OpDecorate
            const target = replacements.get(words[pos + 1]) orelse words[pos + 1];
            const dec = words[pos + 2]; // decoration enum
            var dh: u64 = @as(u64, target) *% 33 +% @as(u64, dec);
            // Include extra operands in hash
            var di: u32 = 3;
            while (di < wc) : (di += 1) {
                dh = dh *% 33 +% @as(u64, words[pos + di]);
            }
            if (seen_decorations.contains(dh)) {
                pos = ie;
                continue;
            }
            seen_decorations.put(alloc, dh, {}) catch {};
        }
        // Also deduplicate OpMemberDecorate
        if (opcode == 72 and wc >= 4) { // OpMemberDecorate
            const target = replacements.get(words[pos + 1]) orelse words[pos + 1];
            const member = words[pos + 2];
            const dec = words[pos + 3];
            var dh: u64 = @as(u64, target) *% 33 +% @as(u64, member);
            dh = dh *% 33 +% @as(u64, dec);
            var di: u32 = 4;
            while (di < wc) : (di += 1) {
                dh = dh *% 33 +% @as(u64, words[pos + di]);
            }
            if (seen_decorations.contains(dh)) {
                pos = ie;
                continue;
            }
            seen_decorations.put(alloc, dh, {}) catch {};
        }

        const info = compact_ids.getOpInfo(opcode) orelse {
            result.appendSlice(alloc, words[pos..ie]) catch return words;
            pos = ie; continue;
        };

        var wi: u32 = pos + 1;
        result.append(alloc, hdr) catch return words;
        switch (info.fixed) {
            1 => { if (wi < ie) { result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; wi += 1; } },
            2 => {
                if (wi < ie) { result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; wi += 1; }
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
            },
            3 => { if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; wi += 1; },
                'l' => { result.append(alloc, words[wi]) catch return words; wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; },
                'L', 's' => { while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words; },
                'M' => { if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } while (wi < ie) : (wi += 1) result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; },
                'W' => { while (wi + 1 < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; wi += 1; } if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } },
                'E' => { while (wi < ie) { const w = words[wi]; wi += 1; result.append(alloc, w) catch return words; if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (wi < ie) : (wi += 1) result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; },
                else => { result.append(alloc, words[wi]) catch return words; wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words;
        pos = ie;
    }

    if (result.items.len == words.len) { result.deinit(alloc); return words; }
    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Double negation elimination: FNegate(FNegate(x)) → x, SNegate(SNegate(x)) → x.
/// Also handles LogicalNot(LogicalNot(x)) → x and BitwiseNot(BitwiseNot(x)) → x.
pub fn dedupPointerTypes(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    var pointers = std.AutoHashMapUnmanaged(u64, u32).empty; // hash(sc, pointee) -> first_id
    defer pointers.deinit(alloc);
    var replacements = std.AutoHashMapUnmanaged(u32, u32).empty; // dup_id -> first_id
    defer replacements.deinit(alloc);

    // First pass: find duplicate pointer types (OpTypePointer = opcode 32)
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 32 and wc >= 4) { // OpTypePointer: result, storage_class, pointee_type
            const result_id = words[pos + 1];
            const sc = words[pos + 2];
            const pointee = words[pos + 3];
            const h = @as(u64, sc) *% 33 +% @as(u64, pointee);
            if (pointers.get(h)) |first_id| {
                if (first_id != result_id) {
                    try replacements.put(alloc, result_id, first_id);
                }
            } else {
                try pointers.put(alloc, h, result_id);
            }
        }
        pos += wc;
    }

    if (replacements.count() == 0) return words;

    // Second pass: skip duplicate pointers, replace all references
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        // Skip duplicate OpTypePointer
        if (opcode == 32 and wc >= 4 and replacements.contains(words[pos + 1])) {
            pos = ie;
            continue;
        }

        const info = compact_ids.getOpInfo(opcode) orelse {
            result.appendSlice(alloc, words[pos..ie]) catch return words;
            pos = ie; continue;
        };

        var wi: u32 = pos + 1;
        try result.append(alloc, hdr);
        switch (info.fixed) {
            1 => { if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; } },
            2 => {
                if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; }
                if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
            },
            3 => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; },
                'l' => { try result.append(alloc, words[wi]); wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                'L', 's' => { while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]); },
                else => { try result.append(alloc, words[wi]); wi += 1; },
            }
        }
        // Copy any remaining words
        while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]);
        pos = ie;
    }

    return result.toOwnedSlice(alloc) catch return words;
}

pub fn elimSelfRefArithmetic(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    // Remove arithmetic instructions where result_id == any operand (always invalid SPIR-V)
    const bound = words[3];
    if (bound <= 1) return words;

    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    var pos: u32 = 5;
    var any_removed = false;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Check arithmetic ops (126-148) for self-reference
        if (opcode >= 126 and opcode <= 148 and wc >= 5) {
            const result_id = words[pos + 2];
            var is_self_ref = false;
            // Check operands starting at word 3
            var wi: u32 = pos + 3;
            while (wi < ie) : (wi += 1) {
                if (words[wi] == result_id) {
                    is_self_ref = true;
                    break;
                }
            }
            if (is_self_ref) {
                any_removed = true;
                pos = ie;
                continue;
            }
        }

        result.appendSliceAssumeCapacity(words[pos..ie]);
        pos = ie;
    }

    if (!any_removed) {
        result.deinit(alloc);
        return words;
    }
    return result.toOwnedSlice(alloc) catch return words;
}

pub fn eliminateDoubleNegate(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Collect negate instructions: map result_id -> (opcode, operand_id)
    // OpFNegate = 127, OpSNegate = 126, OpNot (bitwise) = 200, OpLogicalNot = 168
    var neg_ops = std.AutoHashMapUnmanaged(u32, struct { opcode: u16, operand: u32 }).empty;
    defer neg_ops.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if ((opcode == 126 or opcode == 127 or opcode == 168 or opcode == 200) and wc == 4) {
            const result_id = words[pos + 2];
            const operand = words[pos + 3];
            try neg_ops.put(alloc, result_id, .{ .opcode = opcode, .operand = operand });
        }
        pos += wc;
    }

    // Find double negations: negate(negate(x)) → x
    var replacements = std.AutoHashMapUnmanaged(u32, u32).empty; // result_id -> inner_operand
    defer replacements.deinit(alloc);

    var it = neg_ops.iterator();
    while (it.next()) |entry| {
        const outer_result = entry.key_ptr.*;
        const outer_opcode = entry.value_ptr.opcode;
        const inner_id = entry.value_ptr.operand;
        // Check if the inner is also a negate of the same type
        if (neg_ops.get(inner_id)) |inner| {
            if (inner.opcode == outer_opcode) {
                try replacements.put(alloc, outer_result, inner.operand);
            }
        }
    }

    if (replacements.count() == 0) return words;

    // Rewrite: skip negated instructions whose result is replaced, replace operand references
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        // Skip the outer negate instruction if its result is being replaced
        if ((opcode == 126 or opcode == 127 or opcode == 168 or opcode == 200) and wc >= 4 and replacements.contains(words[pos + 2])) {
            pos = ie;
            continue;
        }

        const info = compact_ids.getOpInfo(opcode) orelse {
            result.appendSlice(alloc, words[pos..ie]) catch return words;
            pos = ie; continue;
        };

        var wi: u32 = pos + 1;
        try result.append(alloc, hdr);
        switch (info.fixed) {
            1 => { if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; } },
            2 => {
                if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; }
                if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
            },
            3 => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; },
                'l' => { try result.append(alloc, words[wi]); wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                'L', 's' => { while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]); },
                'M' => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                'W' => { while (wi + 1 < ie) { try result.append(alloc, words[wi]); wi += 1; try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; } if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
                'E' => { while (wi < ie) { const w = words[wi]; wi += 1; try result.append(alloc, w); if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                else => { try result.append(alloc, words[wi]); wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]);
        pos = ie;
    }

    if (result.items.len == words.len) { result.deinit(alloc); return words; }
    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Fold Negate into Add/Sub: FNegate→FAdd/FSub and SNegate→IAdd/ISub.
/// FAdd(x, FNegate(y)) → FSub(x, y), FSub(x, FNegate(y)) → FAdd(x, y)
/// IAdd(x, SNegate(y)) → ISub(x, y), ISub(x, SNegate(y)) → IAdd(x, y)
/// This eliminates unnecessary negation instructions.
pub fn foldNegateIntoAddSub(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build map of negate results: result_id -> operand_id
    // FNegate=127, SNegate=126
    var neg_map = std.AutoHashMapUnmanaged(u32, struct { operand: u32, is_float: bool }).empty;
    defer neg_map.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if ((opcode == 127 or opcode == 126) and wc == 4) {
            const result_id = words[pos + 2];
            const operand = words[pos + 3];
            try neg_map.put(alloc, result_id, .{ .operand = operand, .is_float = opcode == 127 });
        }
        pos += wc;
    }

    if (neg_map.count() == 0) return words;

    // Phase 2: Scan add/sub and check if an operand is a negate result
    // FAdd=129, FSub=131 (float), IAdd=128, ISub=130 (int)
    var changed = false;
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        if (wc == 5) {
            const result_type = words[pos + 1];
            const result_id = words[pos + 2];
            const a = words[pos + 3];
            const b = words[pos + 4];

            // Determine the add/sub/negate opcodes based on float vs int
            const is_float = (opcode == 129 or opcode == 131);
            const is_int = (opcode == 128 or opcode == 130);

            if (is_float or is_int) {
                const neg_a = neg_map.get(a);
                const neg_b = neg_map.get(b);

                // Match negate type to arithmetic type
                const neg_a_match: ?@TypeOf(neg_a.?) = if (neg_a) |n| if (n.is_float == is_float) n else null else null;
                const neg_b_match: ?@TypeOf(neg_b.?) = if (neg_b) |n| if (n.is_float == is_float) n else null else null;

                const is_add = (opcode == 129 or opcode == 128);

                if (is_add) {
                    if (neg_b_match) |nb| {
                        // Add(x, -y) → Sub(x, y)
                        const sub_op: u16 = if (is_float) 131 else 130;
                        const new_hdr = (wc << 16) | sub_op;
                        try result.appendSlice(alloc, &[_]u32{ new_hdr, result_type, result_id, a, nb.operand });
                        changed = true;
                        pos = ie;
                        continue;
                    } else if (neg_a_match) |na| {
                        // Add(-y, x) → Sub(x, y)
                        const sub_op: u16 = if (is_float) 131 else 130;
                        const new_hdr = (wc << 16) | sub_op;
                        try result.appendSlice(alloc, &[_]u32{ new_hdr, result_type, result_id, b, na.operand });
                        changed = true;
                        pos = ie;
                        continue;
                    }
                } else { // Sub
                    if (neg_b_match) |nb| {
                        // Sub(x, -y) → Add(x, y)
                        const add_op: u16 = if (is_float) 129 else 128;
                        const new_hdr = (wc << 16) | add_op;
                        try result.appendSlice(alloc, &[_]u32{ new_hdr, result_type, result_id, a, nb.operand });
                        changed = true;
                        pos = ie;
                        continue;
                    }
                }
            }
        }

        try result.appendSlice(alloc, words[pos..ie]);
        pos = ie;
    }

    if (!changed) {
        result.deinit(alloc);
        return words;
    }

    // DCE to remove now-dead negate instructions
    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Redundant store elimination: remove stores to function-local variables
/// that are overwritten by a subsequent store in the same basic block
/// without an intervening load.
pub fn redundantStoreElim(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build var -> storage_class map for variables eligible for redundant store elimination
    // This includes: Function (7), Output (3), and Private (6) storage classes
    // These are all per-invocation and only the final value matters
    var trackable = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer trackable.deinit();

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 59 and wc >= 4) { // OpVariable: result_type, result_id, storage_class
            const result_id = words[pos + 2];
            const storage_class = words[pos + 3];
            if ((storage_class == 7 or storage_class == 3 or storage_class == 6 or storage_class == 12) and result_id < bound) {
                trackable.set(result_id);
            }
        }
        pos += wc;
    }

    if (trackable.count() == 0) return words;

    // Phase 2: Scan blocks to find redundant stores
    // Track: for each func-local pointer, the position of the last store
    // If we see another store to the same pointer, mark the first one as dead
    // If we see a load from the pointer, clear the tracking (store is needed)

    // We need to also track AccessChain results derived from func-local vars
    // Stores to AccessChain results also invalidate the var
    var dead_stores = std.AutoHashMapUnmanaged(u32, void).empty; // pos -> dead store
    defer dead_stores.deinit(alloc);

    // Track AC results derived from func-local vars
    var ac_from_func = std.AutoHashMapUnmanaged(u32, void).empty; // ac_result_id -> void
    defer ac_from_func.deinit(alloc);

    // Seed with func-local var ids
    var fl_it = trackable.iterator(.{});
    while (fl_it.next()) |idx| {
        try ac_from_func.put(alloc, @as(u32, @intCast(idx)), {});
    }

    // Propagate through AccessChains
    var changed = true;
    while (changed) {
        changed = false;
        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            if (opcode == 65 and wc >= 4) { // OpAccessChain
                const result_id = words[pos + 2];
                const base_ptr = words[pos + 3];
                if (ac_from_func.contains(base_ptr) and !ac_from_func.contains(result_id) and result_id < bound) {
                    try ac_from_func.put(alloc, result_id, {});
                    changed = true;
                }
            }
            pos += wc;
        }
    }

    // Scan per-block
    var last_store_pos = std.AutoHashMapUnmanaged(u32, u32).empty; // ptr -> last store pos
    defer last_store_pos.deinit(alloc);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;

        if (opcode == 248) { // OpLabel - new block, reset tracking
            last_store_pos.clearRetainingCapacity();
            pos += wc;
            continue;
        }

        if (opcode == 62 and wc >= 2) { // OpStore: ptr, value
            const ptr = words[pos + 1];
            if (ac_from_func.contains(ptr)) {
                // Check if there's a previous store to this pointer
                if (last_store_pos.get(ptr)) |prev_pos| {
                    // Previous store is dead (overwritten without intervening load)
                    try dead_stores.put(alloc, prev_pos, {});
                }
                try last_store_pos.put(alloc, ptr, pos);
            }
            pos += wc;
            continue;
        }

        if (opcode == 61 and wc >= 4) { // OpLoad: type, result, ptr
            const ptr = words[pos + 3];
            // If we load from a tracked pointer, the previous store is NOT dead
            if (ac_from_func.contains(ptr)) {
                // Remove tracking for this pointer (store is needed)
                _ = last_store_pos.remove(ptr);
            }
            pos += wc;
            continue;
        }

        // Reset tracking on operations that may observe stores (barriers, atomics, function calls)
        if (opcode == 57 or // OpFunctionCall
            opcode == 63 or // OpCopyMemory
            opcode == 224 or // OpControlBarrier
            opcode == 225 or // OpMemoryBarrier
            (opcode >= 207 and opcode <= 230)) // Atomic operations
        {
            last_store_pos.clearRetainingCapacity();
            pos += wc;
            continue;
        }

        pos += wc;
    }

    if (dead_stores.count() == 0) return words;

    // Phase 3: Build new binary, skipping dead stores
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        const ie = pos + wc;

        if (dead_stores.contains(pos)) {
            // Skip this dead store
            pos = ie;
            continue;
        }

        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    if (result.items.len == words.len) { result.deinit(alloc); return words; }

    const nw = result.toOwnedSlice(alloc) catch return words;
    // Re-run DCE to clean up values that were only stored in dead stores
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Algebraic simplification: eliminate identity operations at the SPIR-V binary level.
/// - FAdd(x, 0.0) → x
/// - FSub(x, 0.0) → x
/// - IAdd(x, 0) → x
/// - IMul(x, 1) → x
/// - FMul(x, 1.0) → x
/// Also handles vector forms (ConstantComposite of zeros/ones).
pub fn algebraicSimpl(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build type map
    var float_types = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer float_types.deinit();
    var int_types = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer int_types.deinit();

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 22 and wc >= 3) { // OpTypeFloat
            const tid = words[pos + 1];
            if (tid < bound) float_types.set(tid);
        }
        if (opcode == 21 and wc >= 3) { // OpTypeInt
            const tid = words[pos + 1];
            if (tid < bound) int_types.set(tid);
        }
        pos += wc;
    }

    // Phase 2: Collect zero and one constants
    var float_zero_ids = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer float_zero_ids.deinit();
    var float_one_ids = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer float_one_ids.deinit();
    var int_zero_ids = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer int_zero_ids.deinit();
    var int_one_ids = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer int_one_ids.deinit();

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 43 and wc >= 4) { // OpConstant
            const type_id = words[pos + 1];
            const result_id = words[pos + 2];
            if (result_id >= bound) { pos += wc; continue; }
            const val = words[pos + 3];
            if (float_types.isSet(type_id)) {
                if (val == 0 or val == 0x80000000) float_zero_ids.set(result_id);
                if (val == 0x3F800000) float_one_ids.set(result_id);
            }
            if (int_types.isSet(type_id)) {
                if (val == 0) int_zero_ids.set(result_id);
                if (val == 1) int_one_ids.set(result_id);
            }
        }
        pos += wc;
    }

    // Propagate through ConstantComposite
    var changed = true;
    while (changed) {
        changed = false;
        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            if (opcode == 44 and wc >= 4) { // OpConstantComposite
                const result_id = words[pos + 2];
                if (result_id >= bound) { pos += wc; continue; }
                if (float_zero_ids.isSet(result_id) or float_one_ids.isSet(result_id) or
                    int_zero_ids.isSet(result_id) or int_one_ids.isSet(result_id))
                {
                    pos += wc;
                    continue;
                }
                const constituents = words[pos + 3 .. pos + wc];
                if (constituents.len == 0) { pos += wc; continue; }
                var all_fz = true;
                var all_fo = true;
                var all_iz = true;
                var all_io = true;
                for (constituents) |c| {
                    if (!float_zero_ids.isSet(c)) all_fz = false;
                    if (!float_one_ids.isSet(c)) all_fo = false;
                    if (!int_zero_ids.isSet(c)) all_iz = false;
                    if (!int_one_ids.isSet(c)) all_io = false;
                }
                if (all_fz) { float_zero_ids.set(result_id); changed = true; }
                if (all_fo) { float_one_ids.set(result_id); changed = true; }
                if (all_iz) { int_zero_ids.set(result_id); changed = true; }
                if (all_io) { int_one_ids.set(result_id); changed = true; }
            }
            pos += wc;
        }
    }

    // Phase 3: Find identity operations and build replacement map
    var replacements = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer replacements.deinit(alloc);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (wc >= 5) {
            const result_id = words[pos + 2];
            const a = words[pos + 3];
            const b = words[pos + 4];
            if (result_id > 0 and result_id < bound and a > 0 and a < bound and b > 0 and b < bound) {
                switch (opcode) {
                    129 => { // OpFAdd
                        if (float_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                        if (float_zero_ids.isSet(a)) try replacements.put(alloc, result_id, b);
                    },
                    131 => { // OpFSub
                        // `x - 0.0 = x` is safe. The `x - x` case was BROKEN two ways and is
                        // removed: (a) it mapped the result to operand `b` (= x), so `5.0-5.0`
                        // folded to `5.0`, not `0.0` — a wrong-value miscompile; (b) even a
                        // correct fold to a literal 0 would be wrong for IEEE (`Inf-Inf = NaN`).
                        // Leaving the OpFSub in place computes the right value for every input.
                        if (float_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    136 => { // OpFDiv
                        if (float_one_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    128 => { // OpIAdd
                        if (int_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                        if (int_zero_ids.isSet(a)) try replacements.put(alloc, result_id, b);
                    },
                    130 => { // OpISub
                        // `x - 0 = x` is safe. The `x - x` case is removed: it mapped the
                        // result to operand `b` (= x), so `u - u` folded to `u`, not `0` — a
                        // wrong-value miscompile. (Leaving the OpISub computes the correct 0.)
                        if (int_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    135 => { // OpSDiv
                        if (int_one_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    134 => { // OpUDiv
                        if (int_one_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    132 => { // OpIMul
                        if (int_one_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                        if (int_one_ids.isSet(a)) try replacements.put(alloc, result_id, b);
                        // x * 0 = 0
                        if (int_zero_ids.isSet(b)) try replacements.put(alloc, result_id, b);
                        if (int_zero_ids.isSet(a)) try replacements.put(alloc, result_id, a);
                    },
                    133 => { // OpFMul
                        // `x * 1.0 = x` is exact for ALL float values (incl. NaN/Inf), so it
                        // is safe. `x * 0.0 = 0.0` is NOT: IEEE `Inf*0` and `NaN*0` are NaN,
                        // and OpFMul carries no nnan/ninf fast-math contract — folding it was a
                        // silent-wrong miscompile. Only the identity-multiply fold is kept.
                        if (float_one_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                        if (float_one_ids.isSet(a)) try replacements.put(alloc, result_id, b);
                    },
                    142 => { // OpVectorTimesScalar: only `vec * 1.0 = vec` (NOT `* 0.0` — Inf/NaN * 0 = NaN)
                        if (float_one_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    143 => { // OpMatrixTimesScalar: only `mat * 1.0 = mat` (NOT `* 0.0` — Inf/NaN * 0 = NaN)
                        if (float_one_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    197 => { // OpBitwiseOr
                        if (int_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                        if (int_zero_ids.isSet(a)) try replacements.put(alloc, result_id, b);
                    },
                    198 => { // OpBitwiseXor
                        if (int_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                        if (int_zero_ids.isSet(a)) try replacements.put(alloc, result_id, b);
                    },
                    199 => { // OpBitwiseAnd
                        if (int_zero_ids.isSet(b)) try replacements.put(alloc, result_id, b);
                        if (int_zero_ids.isSet(a)) try replacements.put(alloc, result_id, a);
                    },
                    194 => { // OpShiftRightLogical
                        if (int_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    196 => { // OpShiftLeftLogical
                        if (int_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    else => {},
                }
            }
        }
        pos += wc;
    }

    if (replacements.count() == 0) return words;

    // Phase 3.5: Double negation: FNegate(FNegate(x)) -> x, SNegate(SNegate(x)) -> x
    {
        var unary_ops = std.AutoHashMapUnmanaged(u32, struct { opcode: u16, operand: u32 }).empty;
        defer unary_ops.deinit(alloc);
        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            const ie = pos + wc;
            if (ie > words.len) break;
            if ((opcode == 126 or opcode == 127) and wc >= 4) { // SNegate or FNegate
                const result_id = words[pos + 2];
                const operand = words[pos + 3];
                if (result_id > 0 and result_id < bound) {
                    unary_ops.put(alloc, result_id, .{ .opcode = opcode, .operand = operand }) catch {};
                }
            }
            pos = ie;
        }
        // Check for double negation chains
        var it = unary_ops.iterator();
        while (it.next()) |entry| {
            const outer_id = entry.key_ptr.*;
            const outer_op = entry.value_ptr.opcode;
            const inner_id = entry.value_ptr.operand;
            if (unary_ops.get(inner_id)) |inner| {
                if (inner.opcode == outer_op) {
                    const inner_operand = inner.operand;
                    const final_val = replacements.get(inner_operand) orelse inner_operand;
                    replacements.put(alloc, outer_id, final_val) catch {};
                }
            }
        }
    }

    if (replacements.count() == 0) return words;

    // Phase 4: Rewrite
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        // Rewrite using getOpInfo for correct operand handling
        const info = compact_ids.getOpInfo(opcode) orelse {
            // No info — just copy, but still replace IDs in operands
            var ri: u32 = pos;
            while (ri < ie) : (ri += 1) {
                const w = words[ri];
                try result.append(alloc, replacements.get(w) orelse w);
            }
            pos = ie;
            continue;
        };

        // Skip eliminated instructions: only instructions that DEFINE a result id
        // can be eliminated, and the result id lives at a position determined by
        // info.fixed (2 => type+result at pos+2; 3 => result-only at pos+1).
        // Result-less instructions (fixed 0/1, e.g. OpStore, OpBranch, OpDecorate)
        // have NO result id — `words[pos+2]` there is an OPERAND, so they must
        // never be dropped just because that operand was folded away. Treating an
        // operand as a result id (the previous `words[pos+2]` shortcut) silently
        // deleted live OpStores whose stored value was an identity-folded result,
        // which then orphaned the store's type chain (dangling OpTypeVector).
        switch (info.fixed) {
            2 => { if (pos + 2 < ie) {
                const rid = words[pos + 2];
                if (rid > 0 and rid < bound and replacements.contains(rid)) { pos = ie; continue; }
            } },
            3 => { if (pos + 1 < ie) {
                const rid = words[pos + 1];
                if (rid > 0 and rid < bound and replacements.contains(rid)) { pos = ie; continue; }
            } },
            else => {},
        }

        var wi: u32 = pos + 1;
        try result.append(alloc, hdr);
        // Handle fixed part
        switch (info.fixed) {
            0 => {}, // no type or result
            1 => { // type only
                if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; }
            },
            2 => { // type + result
                if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
                if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
            },
            3 => { // result only
                if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
            },
            else => {},
        }
        // Handle variable operands
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; },
                'l' => { try result.append(alloc, words[wi]); wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                'L', 's' => { while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]); },
                'M' => {
                    if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
                    while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]);
                },
                'W' => {
                    while (wi + 1 < ie) {
                        try result.append(alloc, words[wi]); wi += 1;
                        try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1;
                    }
                    if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
                },
                'E' => {
                    while (wi < ie) {
                        const w = words[wi]; wi += 1;
                        try result.append(alloc, w);
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break;
                    }
                    while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]);
                },
                else => { try result.append(alloc, words[wi]); wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]);
        pos = ie;
    }

    if (result.items.len == words.len) { result.deinit(alloc); return words; }
    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Inline trivial void functions with no parameters.
/// A function is "trivially inlineable" if:
/// - Returns void
/// - Has no parameters
/// - Has a single basic block (no control flow)
/// - Body contains no OpVariable, OpLabel (besides entry), OpBranch
/// Inlining replaces OpFunctionCall with the body instructions.
/// Inline simple single-block functions with parameter substitution and ID renaming.
/// A function is inlineable if: single basic block, no OpVariable/OpFunctionCall/branches.
/// Replace OpFunctionCall to functions whose body is only OpUnreachable with OpUndef.
/// This allows subsequent inlining to handle the caller (which no longer has OpFunctionCall).
pub fn elimUnreachableCalls(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Collect entry point function IDs (never remove these)
    var entry_point_funcs = std.AutoHashMapUnmanaged(u32, void).empty;
    defer entry_point_funcs.deinit(alloc);
    {
        var p: u32 = 5;
        while (p < words.len) {
            const h = words[p];
            const w = h >> 16;
            const op: u16 = @truncate(h & 0xFFFF);
            if (w == 0) break;
            if (op == 15 and w >= 4) { // OpEntryPoint
                entry_point_funcs.put(alloc, words[p + 2], {}) catch {};
            }
            p += w;
            if (p > words.len) break;
        }
    }

    // Phase 1: Find functions whose body (after OpLabel) is only OpUnreachable
    // Skip entry point functions even if body is unreachable
    var unreachable_funcs = std.AutoHashMapUnmanaged(u32, void).empty;
    defer unreachable_funcs.deinit(alloc);

    var cur_func: u32 = 0;
    var body_after_label = std.ArrayListUnmanaged(u16).empty;
    defer body_after_label.deinit(alloc);
    var in_body = false;

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 54 and wc >= 3) { // OpFunction
            // Check previous function
            if (cur_func > 0 and in_body) {
                var all_unreachable = true;
                for (body_after_label.items) |op| {
                    if (op != 255) { all_unreachable = false; break; } // not OpUnreachable
                }
                if (all_unreachable and body_after_label.items.len > 0) {
                    if (!entry_point_funcs.contains(cur_func)) {
                        unreachable_funcs.put(alloc, cur_func, {}) catch return words;
                    }
                }
            }
            cur_func = words[pos + 2];
            in_body = false;
            body_after_label.clearRetainingCapacity();
        }
        if (opcode == 248 and cur_func > 0) { // OpLabel — body starts
            in_body = true;
            body_after_label.clearRetainingCapacity();
        }
        if (opcode == 56) { // OpFunctionEnd
            if (cur_func > 0 and in_body) {
                var all_unreachable = true;
                for (body_after_label.items) |op| {
                    if (op != 255) { all_unreachable = false; break; }
                }
                if (all_unreachable and body_after_label.items.len > 0) {
                    if (!entry_point_funcs.contains(cur_func)) {
                        unreachable_funcs.put(alloc, cur_func, {}) catch return words;
                    }
                }
            }
            cur_func = 0;
            in_body = false;
        }
        if (in_body and opcode != 248) {
            body_after_label.append(alloc, opcode) catch return words;
        }
        pos = ie;
    }

    if (unreachable_funcs.count() == 0) return words;

    // Phase 2: Replace OpFunctionCall to unreachable funcs with OpUndef for the result
    // Also remove the unreachable function definitions
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    defer result.deinit(alloc);
    result.appendSliceAssumeCapacity(words[0..5]); // header

    var skip_func: ?u32 = null;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip unreachable function definitions
        if (opcode == 54) {
            if (unreachable_funcs.contains(words[pos + 2])) {
                skip_func = words[pos + 2];
            }
        }
        if (skip_func != null) {
            if (opcode == 56) skip_func = null; // clear AFTER skip
            pos = ie;
            continue;
        }

        // Skip OpName for removed functions (forward reference to deleted ID)
        if (opcode == 5 and wc >= 3) { // OpName
            if (unreachable_funcs.contains(words[pos + 1])) {
                pos = ie;
                continue;
            }
        }

        // Replace OpFunctionCall to unreachable func
        if (opcode == 57 and wc >= 4) { // OpFunctionCall
            const called_func = words[pos + 3];
            if (unreachable_funcs.contains(called_func)) {
                // Replace with OpUndef for the result
                const result_type = words[pos + 1];
                const result_id = words[pos + 2];
                // OpUndef: (3 << 16) | 1, result_type, result_id
                result.append(alloc, (3 << 16) | 1) catch return words;
                result.append(alloc, result_type) catch return words;
                result.append(alloc, result_id) catch return words;
                pos = ie;
                continue;
            }
        }

        result.appendSliceAssumeCapacity(words[pos..ie]);
        pos = ie;
    }

    const out = result.toOwnedSlice(alloc) catch return words;
    return out;
}

/// Inline single-block functions with parameters and/or return values.
/// Body result IDs are renamed to fresh IDs to avoid clashes with the caller.
/// For non-void functions, the return value maps to the call's result ID.
pub fn inlineTrivialFuncs(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    var bound = words[3];
    if (bound <= 1) return words;

    const FuncInfo = struct {
        func_id: u32,
        type_id: u32,
        start_pos: u32,
        end_pos: u32,
        body_start: u32,
        body_end: u32,
        param_ids: []const u32,
        return_value_id: u32, // the ID used in OpReturnValue (0 if void)
        is_inlineable: bool,
    };
    var funcs = std.ArrayListUnmanaged(FuncInfo).empty;
    defer funcs.deinit(alloc);
    var param_slices = std.ArrayListUnmanaged([]const u32).empty;
    defer {
        for (param_slices.items) |sl| alloc.free(sl);
        param_slices.deinit(alloc);
    }

    // Scan functions
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (opcode == 54 and wc >= 5) { // OpFunction
            const func_type = words[pos + 1];
            const func_id = words[pos + 2];
            var func_end = ie;
            var body_start: u32 = 0;
            var body_end: u32 = 0;
            var block_count: u32 = 0;
            var has_call_or_cf = false; // calls, branch, merge — prevents inlining
            var has_var = false; // OpVariable in body — allowed but needs var reordering
            var return_value_id: u32 = 0;
            var param_ids = std.ArrayListUnmanaged(u32).empty;

            var fp = ie;
            while (fp < words.len) {
                const fh = words[fp]; const fwc: u32 = fh >> 16; const fop: u16 = @truncate(fh & 0xFFFF);
                if (fwc == 0) break;
                const fie = fp + fwc;
                if (fop == 56) { func_end = fie; break; }
                if (fop == 55 and fwc >= 3) try param_ids.append(alloc, words[fp + 2]);
                if (fop == 248) { block_count += 1; if (block_count == 1) body_start = fie; }
                if (fop == 59) has_var = true; // OpVariable — allowed for single-block inlining
                if (fop == 57) has_call_or_cf = true; // OpFunctionCall
                if (fop == 249 or fop == 250 or fop == 251) { if (block_count <= 1) has_call_or_cf = true; }
                if (fop == 246 or fop == 247) has_call_or_cf = true;
                if (fop == 253) body_end = fp; // OpReturn
                if (fop == 254 and fwc >= 2) { body_end = fp; return_value_id = words[fp + 1]; }
                fp = fie;
            }
            const is_inlineable = block_count == 1 and !has_call_or_cf and body_start > 0 and body_end >= body_start;
            const ps = try param_ids.toOwnedSlice(alloc);
            try param_slices.append(alloc, ps);
            try funcs.append(alloc, .{
                .func_id = func_id, .type_id = func_type,
                .start_pos = pos, .end_pos = func_end,
                .body_start = body_start, .body_end = body_end,
                .param_ids = ps, .return_value_id = return_value_id,
                .is_inlineable = is_inlineable,
            });
            pos = func_end;
            continue;
        }
        pos = ie;
    }

    // Build inlineable set
    var inlineable = std.AutoHashMapUnmanaged(u32, *const FuncInfo).empty;
    defer inlineable.deinit(alloc);
    for (funcs.items) |*fi| {
        if (fi.is_inlineable) try inlineable.put(alloc, fi.func_id, fi);
    }
    if (inlineable.count() == 0) return words;

    // Check for calls
    var has_calls = false;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 57 and wc >= 4 and inlineable.contains(words[pos + 3])) { has_calls = true; break; }
        pos += wc;
    }
    if (!has_calls) return words;

    // Helper: collect result IDs from a body range and allocate fresh IDs
    const allocFreshIds = struct {
        fn run(allocator: std.mem.Allocator, w: []const u32, bs: u32, be: u32, ret_id: u32, bnd: *u32) !std.AutoHashMapUnmanaged(u32, u32) {
            var result_ids = std.AutoHashMapUnmanaged(u32, u32).empty;
            var bp: u32 = bs;
            while (bp < be) {
                const bh = w[bp]; const bwc: u32 = bh >> 16; const bop: u16 = @truncate(bh & 0xFFFF);
                if (bwc == 0) break;
                const info = compact_ids.getOpInfo(bop) orelse { bp += bwc; continue; };
                if (info.fixed == 2 and bp + 2 < be) { // type + result
                    const rid = w[bp + 2];
                    if (rid != ret_id) { // don't rename return value (it maps to call result)
                        const fresh = bnd.*;
                        bnd.* += 1;
                        try result_ids.put(allocator, rid, fresh);
                    }
                } else if (info.fixed == 3 and bp + 1 < be) { // result only
                    const rid = w[bp + 1];
                    if (rid != ret_id) {
                        const fresh = bnd.*;
                        bnd.* += 1;
                        try result_ids.put(allocator, rid, fresh);
                    }
                }
                bp += bwc;
            }
            return result_ids;
        }
    }.run;

    // Helper: copy body with replacements
    const copyBody = struct {
        fn run(allocator: std.mem.Allocator, w: []const u32, bs: u32, be: u32, repl: std.AutoHashMapUnmanaged(u32, u32), out: *std.ArrayList(u32)) !void {
            var bp: u32 = bs;
            while (bp < be) {
                const bh = w[bp]; const bwc: u32 = bh >> 16; const bop: u16 = @truncate(bh & 0xFFFF);
                if (bwc == 0) break;
                const bie = bp + bwc;
                const info = compact_ids.getOpInfo(bop) orelse {
                    try out.append(allocator, bh);
                    var bi: u32 = bp + 1;
                    while (bi < bie) : (bi += 1) try out.append(allocator, repl.get(w[bi]) orelse w[bi]);
                    bp = bie; continue;
                };
                try out.append(allocator, bh);
                var wi: u32 = bp + 1;
                // Handle fixed part: type (no replace), result (replace)
                switch (info.fixed) {
                    0 => {},
                    1 => { // result_type only — don't replace (it's a type)
                        if (wi < bie) { try out.append(allocator, w[wi]); wi += 1; }
                    },
                    2 => { // result_type + result_id
                        if (wi < bie) { try out.append(allocator, w[wi]); wi += 1; } // type — keep
                        if (wi < bie) { try out.append(allocator, repl.get(w[wi]) orelse w[wi]); wi += 1; } // result — rename
                    },
                    3 => { // result_id only
                        if (wi < bie) { try out.append(allocator, repl.get(w[wi]) orelse w[wi]); wi += 1; } // result — rename
                    },
                    else => {},
                }
                // Handle variable operands
                for (info.ops) |ch| {
                    if (wi >= bie) break;
                    switch (ch) {
                        'i' => { try out.append(allocator, repl.get(w[wi]) orelse w[wi]); wi += 1; },
                        'l' => { try out.append(allocator, w[wi]); wi += 1; },
                        'I' => { while (wi < bie) : (wi += 1) try out.append(allocator, repl.get(w[wi]) orelse w[wi]); },
                        'L', 's' => { while (wi < bie) : (wi += 1) try out.append(allocator, w[wi]); },
                        'M' => {
                            if (wi < bie) { try out.append(allocator, w[wi]); wi += 1; }
                            while (wi < bie) : (wi += 1) try out.append(allocator, repl.get(w[wi]) orelse w[wi]);
                        },
                        'W' => {
                            while (wi + 1 < bie) {
                                try out.append(allocator, w[wi]); // literal
                                wi += 1;
                                try out.append(allocator, repl.get(w[wi]) orelse w[wi]); // target
                                wi += 1;
                            }
                            if (wi < bie) { try out.append(allocator, w[wi]); wi += 1; }
                        },
                        'E' => {
                            var in_str = true;
                            while (wi < bie and in_str) : (wi += 1) {
                                const ww = w[wi]; try out.append(allocator, ww);
                                if ((ww & 0xFF) == 0 or ((ww >> 8) & 0xFF) == 0 or ((ww >> 16) & 0xFF) == 0 or ((ww >> 24) & 0xFF) == 0) in_str = false;
                            }
                            while (wi < bie) : (wi += 1) try out.append(allocator, repl.get(w[wi]) orelse w[wi]);
                        },
                        else => { try out.append(allocator, w[wi]); wi += 1; },
                    }
                }
                while (wi < bie) : (wi += 1) try out.append(allocator, w[wi]);
                bp = bie;
            }
        }
    }.run;

    // Rewrite with persistent substitution map for cross-instruction replacement
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]); // header (magic, version, generator, bound, schema)

    // Persistent substitution map: for non-void inlines where return value is
    // not a body-defined ID (e.g., a constant), replace call_result with return
    // value in all subsequent instructions.
    var sub_map = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer sub_map.deinit(alloc);

    // Helper: apply sub_map to a single instruction and append to result
    const applySub = struct {
        fn run(allocator: std.mem.Allocator, w: []const u32, p: u32, _ie: u32, sm: std.AutoHashMapUnmanaged(u32, u32), out: *std.ArrayList(u32)) !void {
            _ = _ie;
            const bh = w[p]; const bwc: u32 = bh >> 16; const bop: u16 = @truncate(bh & 0xFFFF);
            const bie = p + bwc;
            const info = compact_ids.getOpInfo(bop) orelse {
                // Unknown opcode — simple word-by-word substitution
                try out.append(allocator, bh);
                var bi: u32 = p + 1;
                while (bi < bie) : (bi += 1) try out.append(allocator, sm.get(w[bi]) orelse w[bi]);
                return;
            };
            try out.append(allocator, bh);
            var wi: u32 = p + 1;
            switch (info.fixed) {
                0 => {},
                1 => { if (wi < bie) { try out.append(allocator, sm.get(w[wi]) orelse w[wi]); wi += 1; } },
                2 => {
                    if (wi < bie) { try out.append(allocator, w[wi]); wi += 1; } // type — keep
                    if (wi < bie) { try out.append(allocator, sm.get(w[wi]) orelse w[wi]); wi += 1; } // result
                },
                3 => { if (wi < bie) { try out.append(allocator, sm.get(w[wi]) orelse w[wi]); wi += 1; } },
                else => {},
            }
            for (info.ops) |ch| {
                if (wi >= bie) break;
                switch (ch) {
                    'i' => { try out.append(allocator, sm.get(w[wi]) orelse w[wi]); wi += 1; },
                    'l' => { try out.append(allocator, w[wi]); wi += 1; },
                    'I' => { while (wi < bie) : (wi += 1) try out.append(allocator, sm.get(w[wi]) orelse w[wi]); },
                    'L', 's' => { while (wi < bie) : (wi += 1) try out.append(allocator, w[wi]); },
                    'M' => {
                        if (wi < bie) { try out.append(allocator, w[wi]); wi += 1; }
                        while (wi < bie) : (wi += 1) try out.append(allocator, sm.get(w[wi]) orelse w[wi]);
                    },
                    'W' => {
                        while (wi + 1 < bie) {
                            try out.append(allocator, w[wi]); // literal
                            wi += 1;
                            try out.append(allocator, sm.get(w[wi]) orelse w[wi]); // target
                            wi += 1;
                        }
                        if (wi < bie) { try out.append(allocator, w[wi]); wi += 1; }
                    },
                    'E' => {
                        var in_str = true;
                        while (wi < bie and in_str) : (wi += 1) {
                            const ww = w[wi]; try out.append(allocator, ww);
                            if ((ww & 0xFF) == 0 or ((ww >> 8) & 0xFF) == 0 or ((ww >> 16) & 0xFF) == 0 or ((ww >> 24) & 0xFF) == 0) in_str = false;
                        }
                        while (wi < bie) : (wi += 1) try out.append(allocator, sm.get(w[wi]) orelse w[wi]);
                    },
                    else => { try out.append(allocator, w[wi]); wi += 1; },
                }
            }
            while (wi < bie) : (wi += 1) try out.append(allocator, w[wi]);
        }
    }.run;

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        // Skip OpName for inlineable functions
        if (opcode == 5 and wc >= 3 and inlineable.contains(words[pos + 1])) { pos = ie; continue; }

        // Skip function definitions
        if (opcode == 54 and wc >= 5) {
            if (inlineable.get(words[pos + 2])) |fi| { pos = fi.end_pos; continue; }
        }

        // Inline OpFunctionCall
        if (opcode == 57 and wc >= 4) {
            if (inlineable.get(words[pos + 3])) |fi| {
                // Build replacement map for body copying
                var repl = std.AutoHashMapUnmanaged(u32, u32).empty;
                errdefer repl.deinit(alloc);

                // Param -> arg (apply sub_map to resolve previous inlines)
                const arg_start = pos + 4;
                for (fi.param_ids, 0..) |pid, i| {
                    if (arg_start + i < ie) {
                        const arg = sub_map.get(words[arg_start + i]) orelse words[arg_start + i];
                        try repl.put(alloc, pid, arg);
                    }
                }

                // Allocate fresh IDs for body result IDs (except return value)
                var fresh_map = try allocFreshIds(alloc, words, fi.body_start, fi.body_end, fi.return_value_id, &bound);
                defer fresh_map.deinit(alloc);
                var it = fresh_map.iterator();
                while (it.next()) |entry| try repl.put(alloc, entry.key_ptr.*, entry.value_ptr.*);

                // For non-void: map return value -> call result
                if (fi.return_value_id != 0) {
                    const call_result = words[pos + 2];
                    const resolved_ret = repl.get(fi.return_value_id) orelse fi.return_value_id;
                    // Check if return value is defined in the body (has an instruction producing it)
                    var ret_defined_in_body = false;
                    var bp: u32 = fi.body_start;
                    while (bp < fi.body_end) {
                        const bh = words[bp]; const bwc: u32 = bh >> 16; const bop: u16 = @truncate(bh & 0xFFFF);
                        if (bwc == 0) break;
                        const binfo = compact_ids.getOpInfo(bop) orelse { bp += bwc; continue; };
                        if (binfo.fixed == 2 and bp + 2 < fi.body_end and words[bp + 2] == fi.return_value_id) {
                            ret_defined_in_body = true;
                        } else if (binfo.fixed == 3 and bp + 1 < fi.body_end and words[bp + 1] == fi.return_value_id) {
                            ret_defined_in_body = true;
                        }
                        bp += bwc;
                    }
                    if (fi.body_start < fi.body_end and ret_defined_in_body) {
                        // Return value is defined in the body — map it to call_result
                        try repl.put(alloc, fi.return_value_id, call_result);
                    } else {
                        // Return value is NOT body-defined (e.g., constant or param)
                        // Add to persistent sub_map for subsequent instructions
                        try sub_map.put(alloc, call_result, resolved_ret);
                    }
                }

                try copyBody(alloc, words, fi.body_start, fi.body_end, repl, &result);
                repl.deinit(alloc);
                pos = ie;
                continue;
            }
        }

        // Apply persistent substitution to non-inlined instructions
        // Clear sub_map at function boundaries to prevent cross-function substitutions
        if (opcode == 54) { // OpFunction
            sub_map.clearRetainingCapacity();
        }
        if (sub_map.count() > 0) {
            try applySub(alloc, words, pos, ie, sub_map, &result);
        } else {
            result.appendSlice(alloc, words[pos..ie]) catch return words;
        }
        pos = ie;
    }

    // Update bound
    result.items[3] = bound;

    if (result.items.len == words.len) { result.deinit(alloc); return words; }
    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Move OpVariable instructions to the beginning of their function's entry block.
/// This is needed after inlining functions that contain function-local variables,
/// since SPIR-V requires all OpVariable declarations to appear before any other
/// instructions in a function's entry block.
pub fn moveVarToEntry(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]); // header

    var pos: u32 = 5;
    var any_moved = false;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const inst_end = pos + wc;
        if (inst_end > words.len) break;

        if (opcode != 54 or wc < 5) { // not OpFunction
            result.appendSliceAssumeCapacity(words[pos..inst_end]);
            pos = inst_end;
            continue;
        }

        // Copy OpFunction + parameters
        result.appendSliceAssumeCapacity(words[pos..inst_end]);
        pos = inst_end;
        while (pos < words.len) {
            const ph = words[pos]; const pwc: u32 = ph >> 16; const pop: u16 = @truncate(ph & 0xFFFF);
            if (pwc == 0 or pop != 55) break;
            const pie = pos + pwc;
            result.appendSliceAssumeCapacity(words[pos..pie]);
            pos = pie;
        }

        // Copy first OpLabel
        if (pos >= words.len) break;
        {
            const lh = words[pos]; const lwc: u32 = lh >> 16; const lop: u16 = @truncate(lh & 0xFFFF);
            if (lop != 248) continue;
            result.appendSliceAssumeCapacity(words[pos .. pos + lwc]);
            pos += lwc;
        }

        // Scan rest of function body until OpFunctionEnd
        // Collect ALL OpVariable instructions from ALL blocks to hoist to entry block
        // SPIR-V spec: All OpVariable instructions in a function must be in the first block
        var func_body = std.ArrayList(u32).initCapacity(alloc, words.len - pos) catch return words;
        var all_vars = std.ArrayList(u32).initCapacity(alloc, 64) catch { func_body.deinit(alloc); return words; };
        var found_misplaced = false;
        var label_count: u32 = 0;

        while (pos < words.len) {
            const bh = words[pos];
            const bwc: u32 = bh >> 16;
            const bop: u16 = @truncate(bh & 0xFFFF);
            if (bwc == 0) break;
            const bie = pos + bwc;

            if (bop == 56) { // OpFunctionEnd
                // Emit: entry vars (from all blocks), then body, then FunctionEnd
                if (all_vars.items.len > 0) result.appendSliceAssumeCapacity(all_vars.items);
                if (func_body.items.len > 0) result.appendSliceAssumeCapacity(func_body.items);
                result.appendSliceAssumeCapacity(words[pos..bie]);
                pos = bie;
                break;
            }

            if (bop == 248) { // OpLabel
                label_count += 1;
                try func_body.appendSlice(alloc, words[pos..bie]);
                pos = bie;
                continue;
            }

            if (bop == 59) { // OpVariable
                if (label_count > 1 or func_body.items.len > 0) found_misplaced = true; // var after others or in non-entry block
                try all_vars.appendSlice(alloc, words[pos..bie]);
            } else {
                try func_body.appendSlice(alloc, words[pos..bie]);
            }
            pos = bie;
        }

        if (found_misplaced) any_moved = true;
        all_vars.deinit(alloc);
        func_body.deinit(alloc);
    }

    if (!any_moved) {
        result.deinit(alloc);
        return words;
    }
    return result.toOwnedSlice(alloc) catch return words;
}

/// Eliminate uninitialized variables: function-local vars that are loaded but never stored.
/// Replaces OpLoad from such vars with OpUndef (same type, same result ID),
/// then removes the OpVariable definition. Subsequent DCE will clean up cascading dead code.
pub fn elimUninitVars(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find function-local variables that are loaded but NEVER stored to
    var func_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer func_vars.deinit();
    var loaded_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer loaded_vars.deinit();
    var stored_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer stored_vars.deinit();

    // Track load result -> var_id mapping (for replacing loads with undef)
    var load_to_var = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer load_to_var.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        switch (opcode) {
            59 => { // OpVariable
                if (wc >= 4) {
                    const storage_class = words[pos + 3];
                    if (storage_class == 7) { // Function
                        const var_id = words[pos + 2];
                        if (var_id >= 1 and var_id < bound) {
                            func_vars.set(var_id);
                        }
                    }
                }
            },
            61 => { // OpLoad
                if (wc >= 4) {
                    const ptr = words[pos + 3];
                    const result = words[pos + 2];
                    if (ptr < bound and func_vars.isSet(ptr)) {
                        loaded_vars.set(ptr);
                        try load_to_var.put(alloc, result, ptr);
                    }
                }
            },
            62 => { // OpStore
                if (wc >= 3) {
                    const ptr = words[pos + 1];
                    if (ptr < bound and func_vars.isSet(ptr)) {
                        stored_vars.set(ptr);
                    }
                }
            },
            65 => { // OpAccessChain — conservatively mark as both loaded+stored
                if (wc >= 5) {
                    const base = words[pos + 3];
                    if (base < bound and func_vars.isSet(base)) {
                        loaded_vars.set(base);
                        stored_vars.set(base);
                    }
                }
            },
            12 => { // OpExtInst: may implicitly write to pointer args (Modf, Frexp, etc.)
                // Layout: result_type, result_id, set, literal, then IDs...
                if (wc >= 6) {
                    var ei: u32 = pos + 5;
                    while (ei < ie) : (ei += 1) {
                        const op = words[ei];
                        if (op < bound and func_vars.isSet(op)) {
                            loaded_vars.set(op);
                            stored_vars.set(op); // Modf/Frexp write to pointer arg
                        }
                    }
                }
            },
            57 => { // OpFunctionCall: args may be read/written
                // Layout: result_type, result_id, func_id, arg1, arg2, ...
                if (wc >= 5) {
                    var ai: u32 = pos + 4;
                    while (ai < ie) : (ai += 1) {
                        const op = words[ai];
                        if (op < bound and func_vars.isSet(op)) {
                            loaded_vars.set(op);
                            stored_vars.set(op); // conservatively mark as stored
                        }
                    }
                }
            },
            else => {},
        }
        pos = ie;
    }

    // Find uninit vars: loaded but never stored
    var uninit_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer uninit_vars.deinit();
    var vi: usize = 0;
    while (vi < bound) : (vi += 1) {
        if (func_vars.isSet(vi) and loaded_vars.isSet(vi) and !stored_vars.isSet(vi)) {
            uninit_vars.set(vi);
        }
    }

    if (uninit_vars.count() == 0) return words;

    // Phase 2: Build result instruction map for loads (need their type)
    // We already have load_to_var. Also need load_result -> type_id.
    var load_type = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer load_type.deinit(alloc);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 61 and wc >= 4) { // OpLoad
            const ptr = words[pos + 3];
            if (ptr < bound and uninit_vars.isSet(ptr)) {
                const result_id = words[pos + 2];
                const type_id = words[pos + 1];
                try load_type.put(alloc, result_id, type_id);
            }
        }
        pos = ie;
    }

    // Phase 3: Rewrite — replace OpLoad from uninit vars with OpUndef, remove OpVariable
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Remove OpVariable for uninit vars
        if (opcode == 59 and wc >= 3) {
            const var_id = words[pos + 2];
            if (var_id < bound and uninit_vars.isSet(var_id)) {
                pos = ie;
                continue;
            }
        }

        // Replace OpLoad from uninit var with OpUndef
        if (opcode == 61 and wc >= 4) { // OpLoad
            const ptr = words[pos + 3];
            if (ptr < bound and uninit_vars.isSet(ptr)) {
                const type_id = words[pos + 1];
                const result_id = words[pos + 2];
                // OpUndef: %result_id = OpUndef %type_id
                // Header word: (3 << 16) | 1  (wordcount=3, opcode=1)
                result.appendSliceAssumeCapacity(&.{ (3 << 16) | 1, type_id, result_id });
                pos = ie;
                continue;
            }
        }

        result.appendSliceAssumeCapacity(words[pos..ie]);
        pos = ie;
    }

    return result.toOwnedSlice(alloc) catch return words;
}

/// Fix function-local variables that are accessed (via AccessChain + Load) before their first Store.
/// This can happen when the optimizer eliminates an initial store whose value is used
/// directly as an SSA value, but later component-wise operations still read from the variable.
/// The pass finds the SSA value of the correct type computed right before the first AccessChain
/// and inserts an OpStore to initialize the variable.
pub fn fixEarlyAccessVars(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find function-local variables (storage class 7)
    var func_vars = std.AutoHashMapUnmanaged(u32, void).empty;
    defer func_vars.deinit(alloc);
    // map: var_id -> pointee_type_id
    var var_types = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer var_types.deinit(alloc);
    // map: ptr_type_id -> pointee_type_id
    var ptr_pointee = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer ptr_pointee.deinit(alloc);
    // map: id -> type_id (for result-producing instructions)
    var id_types = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer id_types.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (opcode == 32 and wc >= 4) { // OpTypePointer
            ptr_pointee.put(alloc, words[pos + 1], words[pos + 3]) catch {};
        }
        if (opcode == 59 and wc >= 4 and words[pos + 3] == 7) { // OpVariable Function
            const var_id = words[pos + 2];
            const ptr_type = words[pos + 1];
            func_vars.put(alloc, var_id, {}) catch {};
            if (ptr_pointee.get(ptr_type)) |pt| {
                var_types.put(alloc, var_id, pt) catch {};
            }
        }
        pos = ie;
    }
    if (func_vars.count() == 0) return words;

    // Build id -> type map for all result-producing instructions
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        // Most result instructions have type at words[pos+1] and result at words[pos+2]
        if (wc >= 3) {
            switch (opcode) {
                // Type-defining opcodes (19-33) have different formats where words[pos+1]
                // is the result ID, not a type. Exclude them from id_types to prevent
                // type IDs from being used as values in fixEarlyAccessVars insertions.
                4,5,11,12,17,18,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,196,197,198,199,200 => {
                    id_types.put(alloc, words[pos + 2], words[pos + 1]) catch {};
                },
                else => {},
            }
        }
        pos = ie;
    }

    // Phase 2: For each function-local var, find if AccessChain appears before any Store
    const Insertion = struct { before_pos: u32, var_id: u32, value_id: u32 };
    var insertions = std.ArrayListUnmanaged(Insertion).empty;
    defer insertions.deinit(alloc);

    var fit = func_vars.iterator();
    while (fit.next()) |entry| {
        const var_id = entry.key_ptr.*;
        const pointee_type = var_types.get(var_id) orelse continue;
        var first_ac_pos: u32 = 0;
        var first_store_pos: u32 = 0;

        pos = 5;
        while (pos < words.len) {
            const wc: u32 = words[pos] >> 16;
            if (wc == 0) break;
            const ie = pos + wc;
            if (ie > words.len) break;
            const opcode: u16 = @truncate(words[pos] & 0xFFFF);

            if (opcode == 65 and wc >= 4 and words[pos + 3] == var_id) { // AccessChain base=var
                if (first_ac_pos == 0) first_ac_pos = pos;
            }
            if (opcode == 62 and wc >= 3 and words[pos + 1] == var_id) { // Store to var
                if (first_store_pos == 0) first_store_pos = pos;
            }
            pos = ie;
        }

        // Need fix if AccessChain appears before first Store
        if (first_ac_pos > 0 and (first_store_pos == 0 or first_store_pos > first_ac_pos)) {
            // Find the function boundary containing this variable
            // Search backward from var definition for the OpFunction header
            var func_start: u32 = 5;
            pos = 5;
            while (pos < words.len) {
                const wc_f: u32 = words[pos] >> 16;
                if (wc_f == 0) break;
                const ie_f = pos + wc_f;
                if (ie_f > words.len) break;
                const op_f: u16 = @truncate(words[pos] & 0xFFFF);
                if (op_f == 54) func_start = ie_f; // OpFunction — track last function start
                if (op_f == 56) { // OpFunctionEnd
                    if (pos > first_ac_pos) break; // past our target
                }
                pos = ie_f;
            }
            // func_start now points to the first instruction after the OpFunction header
            // (past the parameters). The entry label is at func_start.
            // Find the function end (OpFunctionEnd)
            var func_end: u32 = @intCast(words.len);
            pos = func_start;
            while (pos < words.len) {
                const wc_f2: u32 = words[pos] >> 16;
                if (wc_f2 == 0) break;
                const ie_f2 = pos + wc_f2;
                if (ie_f2 > words.len) break;
                const op_f2: u16 = @truncate(words[pos] & 0xFFFF);
                if (op_f2 == 56) { func_end = pos; break; } // OpFunctionEnd
                pos = ie_f2;
            }
            // Build set of load result IDs from this variable (to avoid circular: storing load-of-self)
            var loads_from_self = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
            defer loads_from_self.deinit();
            pos = func_start;
            while (pos < func_end) {
                const wc_l: u32 = words[pos] >> 16;
                if (wc_l == 0) break;
                const ie_l = pos + wc_l;
                if (ie_l > words.len) break;
                const op_l: u16 = @truncate(words[pos] & 0xFFFF);
                if (op_l == 61 and wc_l >= 4 and words[pos + 3] == var_id) { // OpLoad from this var
                    const rid_l = words[pos + 2];
                    if (rid_l > 0 and rid_l < bound) loads_from_self.set(rid_l);
                }
                pos = ie_l;
            }
            // Find the last instruction before first_ac_pos that produces a value of pointee_type
            // Don't use results of loads from the same variable (circular)
            var best_val_id: u32 = 0;
            pos = func_start;
            while (pos < func_end and pos < first_ac_pos) {
                const wc: u32 = words[pos] >> 16;
                if (wc == 0) break;
                const ie = pos + wc;
                if (ie > words.len) break;
                if (wc >= 3) {
                    const result_id = words[pos + 2];
                    if (result_id > 0 and result_id < bound and !loads_from_self.isSet(result_id)) {
                        if (id_types.get(result_id)) |tid| {
                            if (tid == pointee_type and result_id != var_id) {
                                best_val_id = result_id;
                            }
                        }
                    }
                }
                pos = ie;
            }
            if (best_val_id != 0) {
                insertions.append(alloc, .{ .before_pos = first_ac_pos, .var_id = var_id, .value_id = best_val_id }) catch {};
            }
        }
    }
    if (insertions.items.len == 0) return words;

    // Phase 3: Insert OpStore before the AccessChain positions
    var result = std.ArrayList(u32).initCapacity(alloc, words.len + insertions.items.len * 3) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]); // header

    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Check if we need to insert before this position
        for (insertions.items) |ins| {
            if (ins.before_pos == pos) {
                // OpStore: (3 << 16) | 62, ptr_id, value_id
                result.append(alloc, (3 << 16) | 62) catch return words;
                result.append(alloc, ins.var_id) catch return words;
                result.append(alloc, ins.value_id) catch return words;
            }
        }

        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    return result.toOwnedSlice(alloc) catch return words;
}

/// Redundant load elimination for read-only variables.
/// Input, UniformConstant, and Uniform storage class variables are never stored to
/// within a shader, so multiple loads of the same variable produce the same value.
/// This pass replaces redundant loads with the first load's result, allowing DCE
/// to eliminate the dead loads and any cascading dead instructions.
pub fn elimRedundantLoads(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Identify read-only variable IDs (Input=1, UniformConstant=2, Uniform=5)
    // Also verify they are never stored to (conservative)
    var readonly_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer readonly_vars.deinit();
    var stored_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer stored_vars.deinit();

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 59 and wc >= 4) { // OpVariable
            const var_id = words[pos + 2];
            const storage_class = words[pos + 3];
            if ((storage_class == 0 or storage_class == 1 or storage_class == 2) and var_id < bound) {
                readonly_vars.set(var_id);
            }
        }
        if (opcode == 62 and wc >= 3) { // OpStore
            const ptr = words[pos + 1];
            if (ptr < bound) stored_vars.set(ptr);
        }
        pos = ie;
    }

    // Remove any readonly vars that are stored to
    var vi: usize = 0;
    while (vi < bound) : (vi += 1) {
        if (stored_vars.isSet(vi)) readonly_vars.unset(vi);
    }

    if (readonly_vars.count() == 0) return words;

    // Phase 1b: Also identify AccessChain results from read-only variables.
    var readonly_ac = std.AutoHashMapUnmanaged(u32, void).empty;
    defer readonly_ac.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 65 and wc >= 5) { // OpAccessChain
            const ac_result = words[pos + 2];
            const base_ptr = words[pos + 3];
            if (base_ptr < bound and readonly_vars.isSet(base_ptr)) {
                if (ac_result < bound) try readonly_ac.put(alloc, ac_result, {});
            } else if (readonly_ac.contains(base_ptr)) {
                if (ac_result < bound) try readonly_ac.put(alloc, ac_result, {});
            }
        }
        pos = ie;
    }

    // Phase 2: Build substitution map for redundant loads
    // Track first load result per read-only var/AC, per function
    var sub_map = std.AutoHashMapUnmanaged(u32, u32).empty; // redundant_load_result -> first_load_result
    defer sub_map.deinit(alloc);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // On OpFunction, scan the function body for redundant loads
        if (opcode == 54) { // OpFunction
            var first_loads = std.AutoHashMapUnmanaged(u32, u32).empty; // var_id -> first_load_result
            defer first_loads.deinit(alloc);
            var in_entry_block = true; // entry block dominates all others

            var fp = ie;
            while (fp < words.len) {
                const fh = words[fp];
                const fwc: u32 = fh >> 16;
                const fop: u16 = @truncate(fh & 0xFFFF);
                if (fwc == 0) break;
                const fie = fp + fwc;
                if (fie > words.len) break;

                if (fop == 56) break; // OpFunctionEnd

                // Clear first_loads when leaving the entry block
                // (entry block loads dominate all blocks, other blocks don't)
                if (fop == 248) { // OpLabel
                    if (in_entry_block) {
                        in_entry_block = false;
                        // Keep first_loads from entry block — they dominate all blocks
                    } else {
                        // Non-entry block: clear first_loads to prevent cross-branch substitution
                        first_loads.clearRetainingCapacity();
                    }
                }

                if (fop == 61 and fwc >= 4) { // OpLoad
                    const result_id = words[fp + 2];
                    const ptr = words[fp + 3];
                    const is_readonly = (ptr < bound and readonly_vars.isSet(ptr)) or readonly_ac.contains(ptr);
                    if (is_readonly) {
                        if (first_loads.get(ptr)) |first_result| {
                            try sub_map.put(alloc, result_id, first_result);
                        } else {
                            try first_loads.put(alloc, ptr, result_id);
                        }
                    }
                }
                fp = fie;
            }
        }
        pos = ie;
    }

    if (sub_map.count() == 0) return words;

    // Phase 3: Apply substitution and remove redundant loads
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip redundant loads entirely
        if (opcode == 61 and wc >= 4) { // OpLoad
            const result_id = words[pos + 2];
            if (sub_map.contains(result_id)) {
                pos = ie;
                continue;
            }
        }

        // Apply substitution to all ID operands
        const info = compact_ids.getOpInfo(opcode) orelse {
            result.append(alloc, hdr) catch return words;
            var wi: u32 = pos + 1;
            while (wi < ie) : (wi += 1) {
                result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
            }
            pos = ie;
            continue;
        };

        result.append(alloc, hdr) catch return words;
        var wi: u32 = pos + 1;

        switch (info.fixed) {
            0 => {},
            1 => {
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
            },
            2 => {
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                if (wi < ie) { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; }
            },
            3 => {
                if (wi < ie) { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; }
            },
            else => {},
        }

        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; },
                'l' => { result.append(alloc, words[wi]) catch return words; wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; },
                'L', 's' => { while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words; },
                'M' => {
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                    while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
                },
                'W' => {
                    while (wi + 1 < ie) {
                        result.append(alloc, words[wi]) catch return words; // literal
                        wi += 1;
                        result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; // target
                        wi += 1;
                    }
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                },
                'E' => {
                    var in_str = true;
                    while (wi < ie and in_str) : (wi += 1) {
                        const w = words[wi]; result.append(alloc, w) catch return words;
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) in_str = false;
                    }
                    while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
                },
                else => { result.append(alloc, words[wi]) catch return words; wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words;
        pos = ie;
    }

    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Fold OpCompositeExtract from OpCompositeConstruct: extract(construct(a,b,...), N) = Nth component.
pub fn foldCompositeExtract(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build map of OpCompositeConstruct: result_id -> []component_ids
    var construct_map = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)){};
    defer {
        var it = construct_map.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(alloc);
        construct_map.deinit(alloc);
    }

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 80 and wc >= 3) { // OpCompositeConstruct
            const result_id = words[pos + 2];
            var components = std.ArrayListUnmanaged(u32).empty;
            var ci: u32 = pos + 3;
            while (ci < ie) : (ci += 1) {
                components.append(alloc, words[ci]) catch return words;
            }
            const gop = construct_map.getOrPut(alloc, result_id) catch return words;
            if (gop.found_existing) gop.value_ptr.deinit(alloc);
            gop.value_ptr.* = components;
        }
        // Also handle OpConstantComposite (44): same format, constituents are constants
        if (opcode == 44 and wc >= 4) { // OpConstantComposite
            const result_id = words[pos + 2];
            var components = std.ArrayListUnmanaged(u32).empty;
            var ci: u32 = pos + 3;
            while (ci < ie) : (ci += 1) {
                components.append(alloc, words[ci]) catch return words;
            }
            construct_map.put(alloc, result_id, components) catch return words;
        }
        pos = ie;
    }

    // Phase 1a: Build map of OpCompositeInsert: result_id -> (object, composite, index)
    // Format: OpCompositeInsert type result object composite index1 [index2...]
    var insert_map = std.AutoHashMapUnmanaged(u32, struct { object: u32, composite: u32, index: u32 }).empty;
    defer insert_map.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        // OpCompositeInsert: type(1) result(1) object(1) composite(1) indices(1+)
        if (opcode == 82 and wc >= 6) {
            const result_id = words[pos + 2];
            const object = words[pos + 3];
            const composite = words[pos + 4];
            // Only handle single-index inserts (multi-index is rare and complex)
            if (wc == 6) { // exactly one index
                const index = words[pos + 5];
                insert_map.put(alloc, result_id, .{ .object = object, .composite = composite, .index = index }) catch {};
            }
        }
        pos = ie;
    }

    // Phase 1b: Build set of IDs that are vector-typed values (for safe extract folding)
    var vector_type_ids = std.AutoHashMapUnmanaged(u32, void).empty;
    defer vector_type_ids.deinit(alloc);
    var vector_value_ids = std.AutoHashMapUnmanaged(u32, void).empty;
    defer vector_value_ids.deinit(alloc);
    // Component count per OpTypeVector id, and per vector-typed VALUE id. Needed by the
    // shuffle-extract fold to use vec1's SOURCE width (not the shuffle result width) as the
    // vec1/vec2 index boundary.
    var type_vec_width = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer type_vec_width.deinit(alloc);
    var value_vec_width = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer value_vec_width.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 23 and wc >= 4) { // OpTypeVector: [op, result_type, component_type, count]
            vector_type_ids.put(alloc, words[pos + 1], {}) catch {};
            type_vec_width.put(alloc, words[pos + 1], words[pos + 3]) catch {};
        }
        // Track IDs whose type is a vector
        const info = compact_ids.getOpInfo(opcode) orelse { pos = ie; continue; };
        switch (info.fixed) {
            2 => { // type + result
                if (pos + 2 < ie and vector_type_ids.contains(words[pos + 1])) {
                    vector_value_ids.put(alloc, words[pos + 2], {}) catch {};
                    if (type_vec_width.get(words[pos + 1])) |w| value_vec_width.put(alloc, words[pos + 2], w) catch {};
                }
            },
            3 => { // result only (no type word in instruction)
                // Skip — can't determine type without context
            },
            else => {},
        }
        pos = ie;
    }

    if (construct_map.count() == 0 and insert_map.count() == 0) return words;

    // Phase 1c: Also build map of OpVectorShuffle: result_id -> (vec1_id, vec2_id, []shuffle_indices)
    var shuffle_map = std.AutoHashMapUnmanaged(u32, struct { vec1: u32, vec2: u32, indices: std.ArrayListUnmanaged(u32) }){};
    defer {
        var sit = shuffle_map.iterator();
        while (sit.next()) |entry| entry.value_ptr.indices.deinit(alloc);
        shuffle_map.deinit(alloc);
    }

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 79 and wc >= 6) { // OpVectorShuffle: type, result, vec1, vec2, indices...
            const result_id = words[pos + 2];
            const vec1_id = words[pos + 3];
            const vec2_id = words[pos + 4];
            var indices = std.ArrayListUnmanaged(u32).empty;
            var si: u32 = pos + 5;
            while (si < ie) : (si += 1) {
                indices.append(alloc, words[si]) catch return words;
            }
            shuffle_map.put(alloc, result_id, .{ .vec1 = vec1_id, .vec2 = vec2_id, .indices = indices }) catch return words;
        }
        pos = ie;
    }

    // Phase 2: Find OpCompositeExtract that can be folded
    var sub_map = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer sub_map.deinit(alloc);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 81 and wc >= 5) { // OpCompositeExtract
            const result_id = words[pos + 2];
            const composite_id = words[pos + 3];
            const index = words[ie - 1]; // last word is the index
            // Try CompositeConstruct/ConstantComposite folding
            // Safe: only fold when constituent is a scalar (not a vector/matrix)
            // When constituent is multi-component (e.g., vec3 in vec4(vec3, 1.0)),
            // the extract index refers to a flattened component, not the constituent index
            if (construct_map.get(composite_id)) |components| {
                if (index < components.items.len) {
                    const constituent = components.items[index];
                    if (!vector_value_ids.contains(constituent)) {
                        try sub_map.put(alloc, result_id, constituent);
                    }
                }
            }
            // Try CompositeInsert folding: Extract(Insert(obj, comp, idx), extract_idx)
            if (insert_map.get(composite_id)) |ins| {
                if (index == ins.index) {
                    // Extracting the inserted element -> return the inserted object
                    try sub_map.put(alloc, result_id, ins.object);
                } else {
                    // Extracting a different element -> extract from the original composite
                    // Chain: follow inserts recursively
                    var comp = ins.composite;
                    var found = false;
                    var depth: u32 = 0;
                    while (depth < 8) : (depth += 1) {
                        if (insert_map.get(comp)) |inner_ins| {
                            if (index == inner_ins.index) {
                                try sub_map.put(alloc, result_id, inner_ins.object);
                                found = true;
                                break;
                            }
                            comp = inner_ins.composite;
                        } else break;
                    }
                    // If not found in insert chain, try construct_map
                    if (!found) {
                        if (construct_map.get(comp)) |components| {
                            if (index < components.items.len) {
                                try sub_map.put(alloc, result_id, components.items[index]);
                                found = true;
                            }
                        }
                    }
                }
            }
        }
        pos = ie;
    }

    if (sub_map.count() == 0) return words;

    // Resolve transitive substitutions
    var changed = true;
    while (changed) {
        changed = false;
        var it = sub_map.iterator();
        while (it.next()) |entry| {
            if (sub_map.get(entry.value_ptr.*)) |resolved| {
                entry.value_ptr.* = resolved;
                changed = true;
            }
        }
    }

    // Phase 2b: Build shuffle-extract rewrite map
    var shuffle_extract_map = std.AutoHashMapUnmanaged(u32, struct { composite: u32, index: u32 }).empty; // extract_result_id -> (new_composite, new_index)
    defer shuffle_extract_map.deinit(alloc);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 81 and wc == 5) { // OpCompositeExtract, SINGLE index (a shuffle result is
            // a vector → only single-index extracts apply; restricting to wc==5 also keeps the
            // emitted 5-word replacement header consistent with the original instruction).
            const result_id = words[pos + 2];
            const composite_id = words[pos + 3];
            const index = words[ie - 1];
            if (shuffle_map.get(composite_id)) |shuffle| {
                if (index < shuffle.indices.items.len) {
                    const shuffle_idx = shuffle.indices.items[index];
                    // The vec1/vec2 boundary is vec1's SOURCE component count, NOT the shuffle
                    // result width. (Using the result width mis-routed e.g. `v.zw` then `.x`:
                    // shuffle_idx 2 with a result width 2 wrongly went to vec2[0] = v.x instead
                    // of vec1[2] = v.z.) `0xFFFFFFFF` is the undefined-component marker — never
                    // fold it. If vec1's width is unknown, skip the fold (leave the extract).
                    if (shuffle_idx != 0xFFFFFFFF) {
                        if (value_vec_width.get(shuffle.vec1)) |vec1_len| {
                            if (shuffle_idx < vec1_len) {
                                try shuffle_extract_map.put(alloc, result_id, .{ .composite = shuffle.vec1, .index = shuffle_idx });
                            } else {
                                try shuffle_extract_map.put(alloc, result_id, .{ .composite = shuffle.vec2, .index = shuffle_idx - vec1_len });
                            }
                        }
                    }
                }
            }
        }
        pos = ie;
    }

    // Phase 3: Apply substitution and remove folded extracts
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip folded extracts (Extract(Construct) -> just use the component)
        if (opcode == 81 and wc >= 5) {
            const result_id = words[pos + 2];
            if (sub_map.contains(result_id)) {
                pos = ie;
                continue;
            }
            // Rewrite Extract(Shuffle) -> Extract(vec, shuffle_idx)
            if (shuffle_extract_map.get(result_id)) |rewr| {
                // OpCompositeExtract: header, result_type, result_id, composite, index
                result.append(alloc, hdr) catch return words;
                result.append(alloc, words[pos + 1]) catch return words; // result_type
                result.append(alloc, result_id) catch return words; // result_id
                result.append(alloc, rewr.composite) catch return words; // new composite (vec1 or vec2)
                result.append(alloc, rewr.index) catch return words; // new index
                pos = ie;
                continue;
            }
        }

        // Apply substitution
        const info = compact_ids.getOpInfo(opcode) orelse {
            result.append(alloc, hdr) catch return words;
            var wi: u32 = pos + 1;
            while (wi < ie) : (wi += 1) {
                result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
            }
            pos = ie;
            continue;
        };

        result.append(alloc, hdr) catch return words;
        var wi: u32 = pos + 1;
        switch (info.fixed) {
            0 => {},
            1 => { if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } },
            2 => {
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                if (wi < ie) { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; }
            },
            3 => { if (wi < ie) { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; },
                'l' => { result.append(alloc, words[wi]) catch return words; wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; },
                'L', 's' => { while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words; },
                'M' => {
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                    while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
                },
                'W' => {
                    while (wi + 1 < ie) {
                        result.append(alloc, words[wi]) catch return words; // literal
                        wi += 1;
                        result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; // target
                        wi += 1;
                    }
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                },
                'E' => {
                    var in_str = true;
                    while (wi < ie and in_str) : (wi += 1) {
                        const w = words[wi]; result.append(alloc, w) catch return words;
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) in_str = false;
                    }
                    while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
                },
                else => { result.append(alloc, words[wi]) catch return words; wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words;
        pos = ie;
    }

    const nw2 = result.toOwnedSlice(alloc) catch return words;
    const dce2 = deadCodeElim(alloc, nw2) catch return nw2;
    if (dce2.ptr != nw2.ptr) alloc.free(nw2);
    return dce2;
}

/// CSE (Common Subexpression Elimination) for OpAccessChain within each function.
/// If two OpAccessChain instructions in the same function have the same
/// (result_type, base, indices...), the second is replaced with the first's result.
pub fn cseWithinBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build substitution map per-function for duplicate AccessChains
    var sub_map = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer sub_map.deinit(alloc);

    // Phase 1b: For each AccessChain, store its signature words so we can dedup
    // Per-block: track signatures and their first result IDs (must be same block for dominance)
    // Also track entry-block AccessChains for cross-block dedup (entry block dominates all)
    const SigEntry = struct { result_id: u32, sig_start: u32, sig_len: u32 };
    var block_sigs = std.ArrayListUnmanaged(SigEntry).empty; // entries for current block
    defer block_sigs.deinit(alloc);
    var entry_block_sigs = std.ArrayListUnmanaged(SigEntry).empty; // entries from function entry block
    defer entry_block_sigs.deinit(alloc);
    var all_sig_words = std.ArrayListUnmanaged(u32).empty; // packed signature words
    defer all_sig_words.deinit(alloc);
    var is_entry_block = true; // track if we're in the function entry block
    var seen_first_label = false;

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Track function and block boundaries
        if (opcode == 54) { // OpFunction — reset
            entry_block_sigs.clearRetainingCapacity();
            block_sigs.clearRetainingCapacity();
            is_entry_block = true;
            seen_first_label = false;
        }
        if (opcode == 248) { // OpLabel — new block
            if (seen_first_label and !is_entry_block) {
                block_sigs.clearRetainingCapacity();
            }
            if (!seen_first_label) {
                seen_first_label = true;
            } else {
                is_entry_block = false; // second label = not entry block
            }
        }

        if (opcode == 65 and wc >= 4) { // OpAccessChain
            const result_id = words[pos + 2]; // result
            const sig_type = words[pos + 1]; // result type
            const sig_base_and_indices = words[pos + 3 .. ie]; // base + indices
            // Opcode-prefixed signature (uniform with the other CSE blocks that share
            // all_sig_words) — see the pure-value-op note below for why the opcode is in the key.
            const sig_len: u32 = 2 + @as(u32, @intCast(sig_base_and_indices.len));

            // Check for duplicate in current block first
            var found_dup = false;
            for (block_sigs.items) |entry| {
                if (entry.sig_len == sig_len) {
                    const existing_sig = all_sig_words.items[entry.sig_start .. entry.sig_start + sig_len];
                    if (existing_sig[0] == @as(u32, opcode) and existing_sig[1] == sig_type and std.mem.eql(u32, existing_sig[2..], sig_base_and_indices)) {
                        try sub_map.put(alloc, result_id, entry.result_id);
                        found_dup = true;
                        break;
                    }
                }
            }
            // If not found in current block, check entry block (dominates all)
            if (!found_dup) {
                for (entry_block_sigs.items) |entry| {
                    if (entry.sig_len == sig_len) {
                        const existing_sig = all_sig_words.items[entry.sig_start .. entry.sig_start + sig_len];
                        if (existing_sig[0] == @as(u32, opcode) and existing_sig[1] == sig_type and std.mem.eql(u32, existing_sig[2..], sig_base_and_indices)) {
                            try sub_map.put(alloc, result_id, entry.result_id);
                            found_dup = true;
                            break;
                        }
                    }
                }
            }
            if (!found_dup) {
                const sig_start: u32 = @intCast(all_sig_words.items.len);
                try all_sig_words.append(alloc, @as(u32, opcode)); // opcode FIRST (uniform key)
                try all_sig_words.append(alloc, sig_type);
                try all_sig_words.appendSlice(alloc, sig_base_and_indices);
                try block_sigs.append(alloc, .{ .result_id = result_id, .sig_start = sig_start, .sig_len = sig_len });
                // Also add to entry_block_sigs if we're in the entry block
                if (is_entry_block) {
                    try entry_block_sigs.append(alloc, .{ .result_id = result_id, .sig_start = sig_start, .sig_len = sig_len });
                }
            }
        }

        // Also CSE OpSampledImage (opcode 86): same (type, image, sampler) = same result
        if (opcode == 86 and wc >= 5) { // OpSampledImage
            const result_id = words[pos + 2]; // result
            const sig_type = words[pos + 1]; // result type
            const sig_operands = words[pos + 3 .. ie]; // image + sampler
            const sig_len: u32 = 2 + @as(u32, @intCast(sig_operands.len)); // opcode-prefixed (uniform key)

            var found_dup = false;
            for (block_sigs.items) |entry| {
                if (entry.sig_len == sig_len) {
                    const existing_sig = all_sig_words.items[entry.sig_start .. entry.sig_start + sig_len];
                    if (existing_sig[0] == @as(u32, opcode) and existing_sig[1] == sig_type and std.mem.eql(u32, existing_sig[2..], sig_operands)) {
                        try sub_map.put(alloc, result_id, entry.result_id);
                        found_dup = true;
                        break;
                    }
                }
            }
            if (!found_dup) {
                for (entry_block_sigs.items) |entry| {
                    if (entry.sig_len == sig_len) {
                        const existing_sig = all_sig_words.items[entry.sig_start .. entry.sig_start + sig_len];
                        if (existing_sig[0] == @as(u32, opcode) and existing_sig[1] == sig_type and std.mem.eql(u32, existing_sig[2..], sig_operands)) {
                            try sub_map.put(alloc, result_id, entry.result_id);
                            found_dup = true;
                            break;
                        }
                    }
                }
            }
            if (!found_dup) {
                const sig_start: u32 = @intCast(all_sig_words.items.len);
                try all_sig_words.append(alloc, @as(u32, opcode)); // opcode FIRST (uniform key)
                try all_sig_words.append(alloc, sig_type);
                try all_sig_words.appendSlice(alloc, sig_operands);
                try block_sigs.append(alloc, .{ .result_id = result_id, .sig_start = sig_start, .sig_len = sig_len });
                if (is_entry_block) {
                    try entry_block_sigs.append(alloc, .{ .result_id = result_id, .sig_start = sig_start, .sig_len = sig_len });
                }
            }
        }
        // Also CSE OpCompositeConstruct (opcode 80) and pure value operations
        // Only include operations that are truly pure (no memory interaction)
        const is_cse_eligible = switch (opcode) {
            79, // OpVectorShuffle
            80, // OpCompositeConstruct
            81, // OpCompositeExtract
            84, // OpTranspose
            126, 127, // SNegate, FNegate
            128, 129, 130, 131, 132, 133, // IAdd, FAdd, ISub, FSub, IMul, FMul
            136, // FDiv
            142, 143, 144, 145, 146, 147, 148, // Vector/Matrix ops
            109, 110, 111, 112, // Conversions
            154, 155, 156, 157, // OpAny, OpAll, OpIsNan, OpIsInf — NOT derivatives (207-215,
            // which are screen-position-dependent and must NOT be CSE-eligible)
            166, 167, 168, 170, 171, // Logical ops
            169, // Select
            177, 178, 179, 180, 182, 184, 186, 188, 190, // Comparisons
            => true,
            else => false,
        };
        if (is_cse_eligible and wc >= 4) {
            const result_id = words[pos + 2]; // result
            const sig_type = words[pos + 1]; // result type
            const sig_operands = words[pos + 3 .. ie]; // constituents
            // The signature MUST include the OPCODE: distinct ops with the same result type
            // and operands (e.g. isnan(v)/isinf(v) → bvecN over the same v, or all(b)/any(b))
            // are NOT redundant. Keying on (type, operands) alone merged them — a silent-wrong.
            const sig_len: u32 = 2 + @as(u32, @intCast(sig_operands.len)); // opcode + type + operands

            var found_dup = false;
            for (block_sigs.items) |entry| {
                if (entry.sig_len == sig_len) {
                    const existing_sig = all_sig_words.items[entry.sig_start .. entry.sig_start + sig_len];
                    if (existing_sig[0] == @as(u32, opcode) and existing_sig[1] == sig_type and std.mem.eql(u32, existing_sig[2..], sig_operands)) {
                        try sub_map.put(alloc, result_id, entry.result_id);
                        found_dup = true;
                        break;
                    }
                }
            }
            if (!found_dup) {
                for (entry_block_sigs.items) |entry| {
                    if (entry.sig_len == sig_len) {
                        const existing_sig = all_sig_words.items[entry.sig_start .. entry.sig_start + sig_len];
                        if (existing_sig[0] == @as(u32, opcode) and existing_sig[1] == sig_type and std.mem.eql(u32, existing_sig[2..], sig_operands)) {
                            try sub_map.put(alloc, result_id, entry.result_id);
                            found_dup = true;
                            break;
                        }
                    }
                }
            }
            if (!found_dup) {
                const sig_start: u32 = @intCast(all_sig_words.items.len);
                try all_sig_words.append(alloc, @as(u32, opcode)); // opcode FIRST (uniform key)
                try all_sig_words.append(alloc, sig_type);
                try all_sig_words.appendSlice(alloc, sig_operands);
                try block_sigs.append(alloc, .{ .result_id = result_id, .sig_start = sig_start, .sig_len = sig_len });
                if (is_entry_block) {
                    try entry_block_sigs.append(alloc, .{ .result_id = result_id, .sig_start = sig_start, .sig_len = sig_len });
                }
            }
        }
        pos = ie;
    }

    if (sub_map.count() == 0) return words;

    // Phase 2: Apply substitution and remove duplicate AccessChains
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip duplicate AccessChains and SampledImages
        const is_cse_eligible_2 = switch (opcode) {
            79, 80, 81, 84, 126, 127, 128, 129, 130, 131, 132, 133, 136, 142, 143, 144, 145, 146, 147, 148,
            109, 110, 111, 112, 154, 155, 156, 157, 166, 167, 168, 170, 171, 169,
            177, 178, 179, 180, 182, 184, 186, 188, 190
            => true,
            else => false,
        };
        if ((opcode == 65 and wc >= 4) or (opcode == 86 and wc >= 5) or (is_cse_eligible_2 and wc >= 4)) {
            const result_id = words[pos + 2];
            if (sub_map.contains(result_id)) {
                pos = ie;
                continue;
            }
        }

        // Apply substitution to ID operands
        const info = compact_ids.getOpInfo(opcode) orelse {
            result.append(alloc, hdr) catch return words;
            var wi: u32 = pos + 1;
            while (wi < ie) : (wi += 1) {
                result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
            }
            pos = ie;
            continue;
        };

        result.append(alloc, hdr) catch return words;
        var wi: u32 = pos + 1;
        switch (info.fixed) {
            0 => {},
            1 => { if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } },
            2 => {
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                if (wi < ie) { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; }
            },
            3 => { if (wi < ie) { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; },
                'l' => { result.append(alloc, words[wi]) catch return words; wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; },
                'L', 's' => { while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words; },
                'M' => {
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                    while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
                },
                'W' => {
                    while (wi + 1 < ie) {
                        result.append(alloc, words[wi]) catch return words; // literal
                        wi += 1;
                        result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; // target
                        wi += 1;
                    }
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                },
                'E' => {
                    var in_str = true;
                    while (wi < ie and in_str) : (wi += 1) {
                        const w = words[wi]; result.append(alloc, w) catch return words;
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) in_str = false;
                    }
                    while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
                },
                else => { result.append(alloc, words[wi]) catch return words; wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words;
        pos = ie;
    }

    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Forward constant stores to function-local variables.
/// If a func-local var is stored exactly once with a constant value,
/// and has no unsafe uses, replace all loads with the constant and
/// remove the var + store. Does NOT run DCE — caller should do that.
pub fn constStoreForward(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Collect constant result IDs (OpConstantTrue/False/Constant/ConstantComposite)
    var const_ids = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer const_ids.deinit();
    {
        var p: u32 = 5;
        while (p < words.len) {
            const hdr = words[p]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            const ie = p + wc;
            if (ie > words.len) break;
            if ((opcode == 41 or opcode == 42 or opcode == 43 or opcode == 44) and wc >= 3) {
                const rid = words[p + 2];
                if (rid >= 1 and rid < bound) const_ids.set(rid);
            }
            p = ie;
        }
    }

    // Phase 2: Find qualifying function-local vars
    var func_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer func_vars.deinit();
    var store_count = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer store_count.deinit(alloc);
    var load_count = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer load_count.deinit(alloc);
    var const_store_val = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer const_store_val.deinit(alloc);
    // Also track non-constant 1-store vars for 1-load forwarding
    var single_store_val = std.AutoHashMapUnmanaged(u32, u32).empty; // var_id -> store_value (for 1-store vars)
    defer single_store_val.deinit(alloc);
    var unsafe_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer unsafe_vars.deinit();

    var in_func = false;
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 54) in_func = true;
        if (opcode == 56) in_func = false;
        if (in_func) {
            if (opcode == 59 and wc >= 4 and words[pos + 3] == 7) {
                const vid = words[pos + 2];
                if (vid >= 1 and vid < bound) func_vars.set(vid);
            }
            if (opcode == 62 and wc >= 3) {
                const ptr = words[pos + 1]; const val = words[pos + 2];
                if (ptr >= 1 and ptr < bound and func_vars.isSet(ptr)) {
                    const entry = try store_count.getOrPutValue(alloc, ptr, 0);
                    entry.value_ptr.* += 1;
                    if (entry.value_ptr.* == 1 and val >= 1 and val < bound and const_ids.isSet(val)) {
                        try const_store_val.put(alloc, ptr, val);
                    } else {
                        _ = const_store_val.remove(ptr);
                    }
                    if (entry.value_ptr.* == 1 and val >= 1 and val < bound) {
                        try single_store_val.put(alloc, ptr, val);
                    } else {
                        _ = single_store_val.remove(ptr);
                    }
                }
            }
            if (opcode == 61 and wc >= 4) {
                const ptr = words[pos + 3];
                if (ptr >= 1 and ptr < bound and func_vars.isSet(ptr)) {
                    const entry = try load_count.getOrPutValue(alloc, ptr, 0);
                    entry.value_ptr.* += 1;
                }
            }
            if (opcode == 65 and wc >= 5 and words[pos + 3] < bound and func_vars.isSet(words[pos + 3])) {
                unsafe_vars.set(words[pos + 3]);
            }
            if (opcode == 63 and wc >= 3) {
                if (words[pos + 1] < bound and func_vars.isSet(words[pos + 1])) unsafe_vars.set(words[pos + 1]);
                if (words[pos + 2] < bound and func_vars.isSet(words[pos + 2])) unsafe_vars.set(words[pos + 2]);
            }
            if (opcode == 12 and wc >= 6) {
                var ei: u32 = pos + 5;
                while (ei < ie) : (ei += 1) {
                    if (words[ei] < bound and func_vars.isSet(words[ei])) unsafe_vars.set(words[ei]);
                }
            }
            if (opcode == 57 and wc >= 5) {
                var ai: u32 = pos + 4;
                while (ai < ie) : (ai += 1) {
                    if (words[ai] < bound and func_vars.isSet(words[ai])) unsafe_vars.set(words[ai]);
                }
            }
        }
        pos = ie;
    }

    // Filter qualifying vars: constant-store or 1-store-1-load non-constant
    {
        var it = const_store_val.keyIterator();
        var to_remove = std.ArrayList(u32).initCapacity(alloc, 16) catch return words;
        defer to_remove.deinit(alloc);
        while (it.next()) |kp| {
            const vid = kp.*;
            const sc = store_count.get(vid) orelse 0;
            if (sc != 1 or unsafe_vars.isSet(vid)) {
                to_remove.append(alloc, vid) catch {};
            }
        }
        for (to_remove.items) |vid| {
            _ = const_store_val.remove(vid);
            _ = single_store_val.remove(vid);
        }
    }
    // Also add 1-store-1-load non-constant vars (not already in const_store_val)
    // With dominance check: only forward if store and load are in the same basic block.
    {
        // Build store position map for qualifying vars
        var store_pos_map = std.AutoHashMapUnmanaged(u32, u32).empty; // var_id -> store position
        defer store_pos_map.deinit(alloc);
        var sit = single_store_val.iterator();
        while (sit.next()) |entry| {
            const vid = entry.key_ptr.*;
            const sc = store_count.get(vid) orelse 0;
            const lc = load_count.get(vid) orelse 0;
            if (sc == 1 and lc == 1 and !unsafe_vars.isSet(vid) and !const_store_val.contains(vid)) {
                // Find store position
                var sp: u32 = 5;
                while (sp < words.len) {
                    const sh = words[sp]; const swc: u32 = sh >> 16; const sop: u16 = @truncate(sh & 0xFFFF);
                    if (swc == 0) break;
                    const sie = sp + swc;
                    if (sie > words.len) break;
                    if (sop == 62 and swc >= 3 and words[sp + 1] == vid) {
                        store_pos_map.put(alloc, vid, sp) catch {};
                        break;
                    }
                    sp = sie;
                }
            }
        }
        // For each qualifying var, find load position and check same-block
        var lit = store_pos_map.iterator();
        while (lit.next()) |entry| {
            const vid = entry.key_ptr.*;
            const st_pos = entry.value_ptr.*;
            // Find store's block
            const store_block = blk: {
                var bp: u32 = 5; var cur: u32 = 0;
                while (bp < words.len) {
                    if (bp == st_pos) break :blk cur;
                    const bh = words[bp]; const bwc: u32 = bh >> 16;
                    if (bwc == 0) break;
                    if ((@as(u16, @truncate(bh & 0xFFFF)) == 248) and bwc >= 2) cur = words[bp + 1];
                    const bie = bp + bwc;
                    if (bie > words.len) break;
                    bp = bie;
                }
                break :blk cur;
            };
            // Find load position and its block
            var load_same_block = true;
            var lp: u32 = 5;
            while (lp < words.len) {
                const lh = words[lp]; const lwc: u32 = lh >> 16; const lop: u16 = @truncate(lh & 0xFFFF);
                if (lwc == 0) break;
                const lie = lp + lwc;
                if (lie > words.len) break;
                if (lop == 61 and lwc >= 4 and words[lp + 3] == vid) {
                    const load_block = blk: {
                        var bp2: u32 = 5; var cur2: u32 = 0;
                        while (bp2 < words.len) {
                            if (bp2 == lp) break :blk cur2;
                            const bh = words[bp2]; const bwc: u32 = bh >> 16;
                            if (bwc == 0) break;
                            if ((@as(u16, @truncate(bh & 0xFFFF)) == 248) and bwc >= 2) cur2 = words[bp2 + 1];
                            const bie = bp2 + bwc;
                            if (bie > words.len) break;
                            bp2 = bie;
                        }
                        break :blk cur2;
                    };
                    if (load_block != store_block) { load_same_block = false; break; }
                }
                lp = lie;
            }
            if (load_same_block) {
                const_store_val.put(alloc, vid, single_store_val.get(vid).?) catch {};
            }
        }
    }

    if (const_store_val.count() == 0) return words;

    // Phase 3: Build load result -> const value substitution map
    var load_fwd = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer load_fwd.deinit(alloc);
    var vars_to_remove = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer vars_to_remove.deinit();
    {
        var kit = const_store_val.keyIterator();
        while (kit.next()) |k| vars_to_remove.set(k.*);
    }

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 61 and wc >= 4) {
            const ptr = words[pos + 3];
            if (ptr < bound and vars_to_remove.isSet(ptr)) {
                try load_fwd.put(alloc, words[pos + 2], const_store_val.get(ptr).?);
            }
        }
        pos = ie;
    }

    if (load_fwd.count() == 0) return words;

    // Phase 4: Rewrite — skip var/store/load for qualifying vars, substitute load results
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip OpVariable/OpStore/OpLoad for qualifying vars
        if (opcode == 59 and wc >= 3 and words[pos + 2] < bound and vars_to_remove.isSet(words[pos + 2])) { pos = ie; continue; }
        if (opcode == 62 and wc >= 3 and words[pos + 1] < bound and vars_to_remove.isSet(words[pos + 1])) { pos = ie; continue; }
        if (opcode == 61 and wc >= 4 and words[pos + 3] < bound and vars_to_remove.isSet(words[pos + 3])) { pos = ie; continue; }

        // Apply substitution using getOpInfo
        const info = compact_ids.getOpInfo(opcode);
        if (info) |inf| {
            result.append(alloc, hdr) catch return words;
            var wi: u32 = pos + 1;
            const fixed = inf.fixed;
            switch (fixed) {
                1 => { if (wi < ie) { result.append(alloc, load_fwd.get(words[wi]) orelse words[wi]) catch return words; wi += 1; } },
                2 => {
                    if (wi < ie) { result.append(alloc, load_fwd.get(words[wi]) orelse words[wi]) catch return words; wi += 1; }
                    if (wi < ie) { result.append(alloc, load_fwd.get(words[wi]) orelse words[wi]) catch return words; wi += 1; }
                },
                else => { var fi: u32 = 0; while (fi < fixed and wi < ie) : ({fi += 1; wi += 1;}) result.append(alloc, words[wi]) catch return words; },
            }
            const ops = inf.ops;
            var ci: usize = 0;
            while (ci < ops.len and wi < ie) : (ci += 1) {
                const ch = ops[ci];
                switch (ch) {
                    'i' => { result.append(alloc, load_fwd.get(words[wi]) orelse words[wi]) catch return words; wi += 1; },
                    'l' => { result.append(alloc, words[wi]) catch return words; wi += 1; },
                    'I' => { while (wi < ie) : (wi += 1) result.append(alloc, load_fwd.get(words[wi]) orelse words[wi]) catch return words; },
                    'L', 's' => { while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words; },
                    'M' => {
                        if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                        while (wi < ie) : (wi += 1) result.append(alloc, load_fwd.get(words[wi]) orelse words[wi]) catch return words;
                    },
                    'W' => {
                        while (wi + 1 < ie) {
                            result.append(alloc, words[wi]) catch return words; wi += 1;
                            result.append(alloc, load_fwd.get(words[wi]) orelse words[wi]) catch return words; wi += 1;
                        }
                        if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                    },
                    'E' => {
                        while (wi < ie) {
                            const w = words[wi]; wi += 1;
                            result.append(alloc, w) catch return words;
                            if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break;
                        }
                        while (wi < ie) : (wi += 1) result.append(alloc, load_fwd.get(words[wi]) orelse words[wi]) catch return words;
                    },
                    else => { result.append(alloc, words[wi]) catch return words; wi += 1; },
                }
            }
            // Remaining words (shouldn't happen for well-formed instructions)
            while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words;
        } else {
            // Unknown opcode — pass through unchanged
            result.appendSlice(alloc, words[pos..ie]) catch return words;
        }
        pos = ie;
    }

    const result_owned = result.toOwnedSlice(alloc) catch {
        result.deinit(alloc);
        return words;
    };
    return result_owned;
}

/// Constant folding: replace binary arithmetic ops where all operands are constants
/// with the computed constant value. Reuses the result ID.
/// Supports: IAdd, ISub, IMul, FAdd, FSub, FMul, FDiv on scalar constants.
pub fn constFold(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build constant value map: result_id -> (type_id, value)
    var const_types = std.AutoHashMapUnmanaged(u32, u32).empty; // result_id -> type_id
    defer const_types.deinit(alloc);
    var const_vals = std.AutoHashMapUnmanaged(u32, u32).empty; // result_id -> literal_value
    defer const_vals.deinit(alloc);
    // Track float vs int types
    var float_types = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer float_types.deinit();
    var int_signed = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer int_signed.deinit();
    var int_unsigned = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer int_unsigned.deinit();
    // Track all defined type IDs for validation
    var defined_types = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer defined_types.deinit();
    // Track bool type and true/false constants for comparison folding
    var bool_type: u32 = 0;
    var true_id: u32 = 0;
    var false_id: u32 = 0;

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode >= 19 and opcode <= 33 and wc >= 2) {
            const tid = words[pos + 1];
            if (tid >= 1 and tid < bound) defined_types.set(tid);
        }
        if (opcode == 22 and wc >= 3) { // OpTypeFloat
            const tid = words[pos + 1];
            if (tid >= 1 and tid < bound) { float_types.set(tid); defined_types.set(tid); }
        }
        if (opcode == 21 and wc >= 4) { // OpTypeInt
            const tid = words[pos + 1];
            const signed: u32 = words[pos + 3];
            if (tid >= 1 and tid < bound) {
                if (signed != 0) int_signed.set(tid) else int_unsigned.set(tid);
                defined_types.set(tid);
            }
        }
        if (opcode == 43 and wc >= 4) { // OpConstant (scalar)
            const rtype = words[pos + 1];
            const rid = words[pos + 2];
            const val = words[pos + 3];
            if (rid >= 1 and rid < bound) {
                try const_types.put(alloc, rid, rtype);
                try const_vals.put(alloc, rid, val);
            }
        }
        if (opcode == 20 and wc >= 2) bool_type = words[pos + 1]; // OpTypeBool
        if (opcode == 41 and wc >= 3) true_id = words[pos + 2]; // OpConstantTrue
        if (opcode == 42 and wc >= 3) false_id = words[pos + 2]; // OpConstantFalse
        pos += wc;
    }

    // Track bool replacements: comparison result_id -> true_id or false_id
    var bool_replacements = std.AutoHashMapUnmanaged(u32, u32).empty; // result_id -> true_id or false_id
    defer bool_replacements.deinit(alloc);

    // Phase 2: Find foldable ops and compute replacement values
    var fold_map = std.AutoHashMapUnmanaged(u32, struct { rtype: u32, val: u32 }).empty;
    defer fold_map.deinit(alloc);
    var to_skip = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer to_skip.deinit();

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) { pos = ie; continue; }

        // Binary arithmetic: result_type, result_id, operand_a, operand_b
        if (wc >= 5) {
            const rtype = words[pos + 1];
            const rid = words[pos + 2];
            const a = words[pos + 3];
            const b = words[pos + 4];

            if (rid >= 1 and rid < bound) {
                const a_val = const_vals.get(a);
                const b_val = const_vals.get(b);
                const a_type = const_types.get(a);
                const b_type = const_types.get(b);

                if (a_val != null and b_val != null and a_type != null and b_type != null) {
                    // Both operands are scalar constants — fold!
                    const av = a_val.?;
                    const bv = b_val.?;
                    const result_type = rtype;
                    var result_val: ?u32 = null;

                    if (float_types.isSet(result_type)) {
                        // Float operations
                        const af: f32 = @bitCast(av);
                        const bf: f32 = @bitCast(bv);
                        var cf: f32 = undefined;
                        switch (opcode) {
                            129 => { cf = af + bf; result_val = @bitCast(cf); }, // FAdd
                            131 => { cf = af - bf; result_val = @bitCast(cf); }, // FSub
                            133 => { cf = af * bf; result_val = @bitCast(cf); }, // FMul
                            136 => { if (bf != 0.0) { cf = af / bf; result_val = @bitCast(cf); } }, // FDiv
                            140 => { if (bf != 0.0) { cf = @rem(af, bf); result_val = @bitCast(cf); } }, // FRem
                            141 => { if (bf != 0.0) { cf = @mod(af, bf); result_val = @bitCast(cf); } }, // FMod
                            else => {},
                        }
                    } else if (int_unsigned.isSet(result_type)) {
                        // Unsigned int operations (32-bit)
                        switch (opcode) {
                            128 => { result_val = av +% bv; }, // IAdd
                            130 => { result_val = av -% bv; }, // ISub
                            132 => { result_val = av *% bv; }, // IMul
                            134 => { if (bv != 0) result_val = av / bv; }, // UDiv
                            137 => { if (bv != 0) result_val = av % bv; }, // UMod
                            194 => { if (bv < 32) result_val = av >> @intCast(bv); }, // ShiftRightLogical
                            196 => { if (bv < 32) result_val = av << @intCast(bv); }, // ShiftLeftLogical
                            197 => { result_val = av | bv; }, // BitwiseOr
                            198 => { result_val = av ^ bv; }, // BitwiseXor
                            199 => { result_val = av & bv; }, // BitwiseAnd
                            else => {},
                        }
                    } else if (int_signed.isSet(result_type)) {
                        // Signed int operations (32-bit, using wrapping for safety)
                        switch (opcode) {
                            128 => { result_val = av +% bv; }, // IAdd
                            130 => { result_val = av -% bv; }, // ISub
                            132 => { result_val = av *% bv; }, // IMul
                            135 => { if (bv != 0) result_val = @bitCast(@divTrunc(@as(i32, @bitCast(av)), @as(i32, @bitCast(bv)))); }, // SDiv
                            196 => { if (bv < 32) result_val = av << @intCast(bv); }, // ShiftLeftLogical
                            197 => { result_val = av | bv; }, // BitwiseOr
                            198 => { result_val = av ^ bv; }, // BitwiseXor
                            199 => { result_val = av & bv; }, // BitwiseAnd
                            else => {},
                        }
                    }

                    if (result_val) |rv| {
                        // Validate: result_type must be a defined type
                        if (result_type < bound and defined_types.isSet(result_type)) {
                            try fold_map.put(alloc, rid, .{ .rtype = result_type, .val = rv });
                            to_skip.set(rid);
                        }
                    }
                }
            }
        }

        // Unary constant folding: SNegate (126), FNegate (127)
        if (wc >= 4) {
            const rtype = words[pos + 1];
            const rid = words[pos + 2];
            const operand = words[pos + 3];
            if (rid >= 1 and rid < bound) {
                if (const_vals.get(operand)) |val| {
                    if (const_types.get(operand)) |_| {
                        var result_val: ?u32 = null;
                        if (opcode == 127 and float_types.isSet(rtype)) { // FNegate
                            const fv: f32 = @bitCast(val);
                            result_val = @bitCast(-fv);
                        } else if (opcode == 126 and (int_signed.isSet(rtype) or int_unsigned.isSet(rtype))) { // SNegate
                            result_val = ~val +% 1; // two's complement negation
                        }
                        if (result_val) |rv| {
                            if (rtype < bound and defined_types.isSet(rtype)) {
                                try fold_map.put(alloc, rid, .{ .rtype = rtype, .val = rv });
                                to_skip.set(rid);
                            }
                        }
                    }
                }
            }
        }

        // Constant comparison folding: both operands are constants -> boolean result
        if (bool_type != 0 and (true_id != 0 or false_id != 0) and wc >= 5) {
            const rid = words[pos + 2];
            const a = words[pos + 3];
            const b = words[pos + 4];
            if (rid >= 1 and rid < bound and
                const_vals.get(a) != null and const_vals.get(b) != null and
                const_types.get(a) != null and const_types.get(b) != null)
            {
                const av = const_vals.get(a).?;
                const bv = const_vals.get(b).?;
                const a_type = const_types.get(a).?;
                var bool_result: ?bool = null;

                if (float_types.isSet(a_type)) {
                    const af: f32 = @bitCast(av);
                    const bf: f32 = @bitCast(bv);
                    switch (opcode) {
                        180 => { bool_result = af == bf; }, // OpFOrdEqual (false for NaN — `==` already gives that)
                        // OpFOrdNotEqual is ORDERED: false when either operand is NaN. Zig's
                        // `af != bf` returns TRUE for NaN, so guard it (the other ordered
                        // comparisons below already yield false for NaN via `< > <= >=`).
                        182 => { bool_result = !std.math.isNan(af) and !std.math.isNan(bf) and af != bf; }, // OpFOrdNotEqual
                        184 => { bool_result = af < bf; },   // OpFOrdLessThan
                        186 => { bool_result = af > bf; },   // OpFOrdGreaterThan
                        188 => { bool_result = af <= bf; },  // OpFOrdLessThanEqual
                        190 => { bool_result = af >= bf; },  // OpFOrdGreaterThanEqual
                        else => {},
                    }
                } else if (int_unsigned.isSet(a_type)) {
                    switch (opcode) {
                        170 => { bool_result = av == bv; }, // OpIEqual
                        171 => { bool_result = av != bv; }, // OpINotEqual
                        172 => { bool_result = av > bv; },  // OpUGreaterThan
                        174 => { bool_result = av >= bv; }, // OpUGreaterThanEqual
                        176 => { bool_result = av < bv; },  // OpULessThan
                        178 => { bool_result = av <= bv; }, // OpULessThanEqual
                        else => {},
                    }
                } else if (int_signed.isSet(a_type)) {
                    const as_i: i32 = @bitCast(av);
                    const bs_i: i32 = @bitCast(bv);
                    switch (opcode) {
                        170 => { bool_result = as_i == bs_i; }, // OpIEqual
                        171 => { bool_result = as_i != bs_i; }, // OpINotEqual
                        173 => { bool_result = as_i > bs_i; },  // OpSGreaterThan
                        175 => { bool_result = as_i >= bs_i; }, // OpSGreaterThanEqual
                        177 => { bool_result = as_i < bs_i; },  // OpSLessThan
                        179 => { bool_result = as_i <= bs_i; }, // OpSLessThanEqual
                        else => {},
                    }
                }

                if (bool_result) |br| {
                    const target = if (br) true_id else false_id;
                    if (target != 0) {
                        bool_replacements.put(alloc, rid, target) catch {};
                        to_skip.set(rid);
                    }
                }
            }
        }

        // Constant logical op folding: LogicalOr/LogicalAnd with boolean constant operands
        if (bool_type != 0 and true_id != 0 and false_id != 0 and wc >= 5) {
            const rid = words[pos + 2];
            const a = words[pos + 3];
            const b = words[pos + 4];
            if (rid >= 1 and rid < bound) {
                const a_is_true = a == true_id;
                const a_is_false = a == false_id;
                const b_is_true = b == true_id;
                const b_is_false = b == false_id;
                if ((a_is_true or a_is_false) and (b_is_true or b_is_false)) {
                    switch (opcode) {
                        166 => { // OpLogicalOr
                            const result = a_is_true or b_is_true;
                            bool_replacements.put(alloc, rid, if (result) true_id else false_id) catch {};
                            to_skip.set(rid);
                        },
                        167 => { // OpLogicalAnd
                            const result = a_is_true and b_is_true;
                            bool_replacements.put(alloc, rid, if (result) true_id else false_id) catch {};
                            to_skip.set(rid);
                        },
                        else => {},
                    }
                }
                // Partial folding: one operand is constant
                if (!to_skip.isSet(rid)) {
                    if (opcode == 166) { // OpLogicalOr
                        if (a_is_true or b_is_true) {
                            // x || true = true
                            bool_replacements.put(alloc, rid, true_id) catch {};
                            to_skip.set(rid);
                        } else if (a_is_false) {
                            // false || b = b
                            bool_replacements.put(alloc, rid, b) catch {};
                            to_skip.set(rid);
                        } else if (b_is_false) {
                            // a || false = a
                            bool_replacements.put(alloc, rid, a) catch {};
                            to_skip.set(rid);
                        }
                    } else if (opcode == 167) { // OpLogicalAnd
                        if (a_is_false or b_is_false) {
                            // x && false = false
                            bool_replacements.put(alloc, rid, false_id) catch {};
                            to_skip.set(rid);
                        } else if (a_is_true) {
                            // true && b = b
                            bool_replacements.put(alloc, rid, b) catch {};
                            to_skip.set(rid);
                        } else if (b_is_true) {
                            // a && true = a
                            bool_replacements.put(alloc, rid, a) catch {};
                            to_skip.set(rid);
                        }
                    }
                }
            }
        }

        // Unary boolean constant folding: OpLogicalNot(true) = false, OpLogicalNot(false) = true
        if (bool_type != 0 and true_id != 0 and false_id != 0 and opcode == 168 and wc == 4) { // OpLogicalNot
            const rid = words[pos + 2];
            const operand = words[pos + 3];
            if (rid >= 1 and rid < bound) {
                if (operand == true_id) {
                    bool_replacements.put(alloc, rid, false_id) catch {};
                    to_skip.set(rid);
                } else if (operand == false_id) {
                    bool_replacements.put(alloc, rid, true_id) catch {};
                    to_skip.set(rid);
                }
            }
        }

        pos = ie;
    }

    if (fold_map.count() == 0 and bool_replacements.count() == 0) return words;

    // Phase 3: Find the insertion point for new OpConstants
    // In SPIR-V, constants come after types and before global variables.
    // Find the position after the last type or constant instruction.
    var insert_point: u32 = 5;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        // Types: 19-31, Constants: 32,33,43,44
        if (opcode >= 19 and opcode <= 33) {
            insert_point = ie;
        }
        if (opcode == 43 or opcode == 44) { // OpConstant, OpConstantComposite
            insert_point = ie;
        }
        // Stop only at OpFunction (section boundary between global and function)
        // Don't stop at OpVariable — pipeline may place types after variables
        if (opcode == 54) break; // OpFunction
        pos = ie;
    }

    // Phase 4: Rewrite — skip foldable ops, insert new OpConstants in the right place
    var result = std.ArrayList(u32).initCapacity(alloc, words.len + fold_map.count() * 4) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]); // header

    var inserted_constants = false;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) { pos = ie; continue; }

        // Skip foldable arithmetic ops (they become constants)
        // Only skip if this instruction DEFINES a result ID that's being folded.
        // Use getOpInfo to determine where the result ID is:
        //   fixed=2: result_type at pos+1, result_id at pos+2 (arithmetic, constants, etc.)
        //   fixed=3: result_id at pos+1 (type definitions — never folded, never skip)
        const info = compact_ids.getOpInfo(opcode);
        const is_arithmetic = info != null and info.?.fixed == 2;
        if (is_arithmetic and wc >= 3 and words[pos + 2] < bound and to_skip.isSet(words[pos + 2])) {
            pos = ie;
            continue;
        }

        // Insert new OpConstants at the right position
        if (!inserted_constants and pos >= insert_point) {
            // Emit all folded constants here
            var it = fold_map.iterator();
            while (it.next()) |entry| {
                const rid = entry.key_ptr.*;
                const fold = entry.value_ptr.*;
                result.append(alloc, (4 << 16) | 43) catch return words; // OpConstant, wc=4
                result.append(alloc, fold.rtype) catch return words;
                result.append(alloc, rid) catch return words; // reuse result_id
                result.append(alloc, fold.val) catch return words;
            }
            inserted_constants = true;
        }

        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    // If we never reached insert_point (shouldn't happen), insert at end
    if (!inserted_constants) {
        var it = fold_map.iterator();
        while (it.next()) |entry| {
            const rid = entry.key_ptr.*;
            const fold = entry.value_ptr.*;
            result.append(alloc, (4 << 16) | 43) catch return words;
            result.append(alloc, fold.rtype) catch return words;
            result.append(alloc, rid) catch return words;
            result.append(alloc, fold.val) catch return words;
        }
    }

    const result_owned = result.toOwnedSlice(alloc) catch {
        result.deinit(alloc);
        return words;
    };

    // Phase 5: Replace operand references for bool_replacements
    // (comparison results folded to existing true_id/false_id)
    if (bool_replacements.count() > 0) {
        const br_result = result_owned;
        var br_out = std.ArrayList(u32).initCapacity(alloc, br_result.len) catch return br_result;
        br_out.appendSliceAssumeCapacity(br_result[0..5]);
        pos = 5;
        while (pos < br_result.len) {
            const bhdr = br_result[pos];
            const bwc: u32 = bhdr >> 16;
            if (bwc == 0) break;
            const bie = pos + bwc;
            if (bie > br_result.len) break;

            // Skip instructions that were folded (their result_id should not appear as operand)
            const binfo = compact_ids.getOpInfo(@as(u16, @truncate(bhdr & 0xFFFF)));
            const b_is_arithmetic = binfo != null and binfo.?.fixed == 2;
            if (b_is_arithmetic and bwc >= 3 and br_result[pos + 2] < bound and
                to_skip.isSet(br_result[pos + 2]))
            {
                pos = bie;
                continue;
            }

            // Rewrite ID operands using bool_replacements (using getOpInfo to skip literals)
            // First, scan ONLY ID positions for any replacements
            const br_opcode: u16 = @truncate(bhdr & 0xFFFF);
            const br_info = compact_ids.getOpInfo(br_opcode);
            var any_replaced = false;
            if (br_info) |info| {
                var bw: u32 = pos + 1;
                switch (info.fixed) {
                    1 => { if (bw < bie) { if (bool_replacements.contains(br_result[bw])) any_replaced = true; bw += 1; } },
                    2 => {
                        if (bw < bie) { if (bool_replacements.contains(br_result[bw])) any_replaced = true; bw += 1; }
                        if (bw < bie) { bw += 1; } // result_id, skip
                    },
                    3 => { if (bw < bie) { bw += 1; } }, // result_id, skip
                    else => {},
                }
                if (!any_replaced) {
                    for (info.ops) |ch| {
                        if (bw >= bie) break;
                        switch (ch) {
                            'i' => { if (bool_replacements.contains(br_result[bw])) { any_replaced = true; break; } bw += 1; },
                            'I' => { while (bw < bie) : (bw += 1) { if (bool_replacements.contains(br_result[bw])) { any_replaced = true; break; } } },
                            'l' => { bw += 1; },
                            'L', 's' => { bw = bie; },
                            'M' => { if (bw < bie) bw += 1; while (bw < bie) : (bw += 1) { if (bool_replacements.contains(br_result[bw])) { any_replaced = true; break; } } },
                            'W' => { while (bw + 1 < bie) { bw += 1; bw += 1; if (bool_replacements.contains(br_result[bw])) { any_replaced = true; break; } } },
                            'E' => { while (bw < bie) { const w = br_result[bw]; bw += 1; if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (bw < bie) : (bw += 1) { if (bool_replacements.contains(br_result[bw])) { any_replaced = true; break; } } },
                            else => { bw += 1; },
                        }
                    }
                }
            }
            if (any_replaced and br_info != null) {
                const info = br_info.?;
                var br_buf = std.ArrayListUnmanaged(u32).initCapacity(alloc, bwc) catch {
                    br_out.appendSlice(alloc, br_result[pos..bie]) catch return br_result;
                    pos = bie;
                    continue;
                };
                br_buf.append(alloc, bhdr) catch return br_result; // header
                var bw: u32 = pos + 1;
                switch (info.fixed) {
                    1 => { if (bw < bie) { br_buf.append(alloc, bool_replacements.get(br_result[bw]) orelse br_result[bw]) catch return br_result; bw += 1; } },
                    2 => {
                        if (bw < bie) { br_buf.append(alloc, bool_replacements.get(br_result[bw]) orelse br_result[bw]) catch return br_result; bw += 1; }
                        if (bw < bie) { br_buf.append(alloc, br_result[bw]) catch return br_result; bw += 1; } // result_id
                    },
                    3 => { if (bw < bie) { br_buf.append(alloc, br_result[bw]) catch return br_result; bw += 1; } },
                    else => {},
                }
                for (info.ops) |ch| {
                    if (bw >= bie) break;
                    switch (ch) {
                        'i' => { br_buf.append(alloc, bool_replacements.get(br_result[bw]) orelse br_result[bw]) catch return br_result; bw += 1; },
                        'I' => { while (bw < bie) : (bw += 1) { br_buf.append(alloc, bool_replacements.get(br_result[bw]) orelse br_result[bw]) catch return br_result; } },
                        'l' => { br_buf.append(alloc, br_result[bw]) catch return br_result; bw += 1; },
                        'L', 's' => { while (bw < bie) : (bw += 1) { br_buf.append(alloc, br_result[bw]) catch return br_result; } },
                        'M' => { if (bw < bie) { br_buf.append(alloc, br_result[bw]) catch return br_result; bw += 1; } while (bw < bie) : (bw += 1) { br_buf.append(alloc, bool_replacements.get(br_result[bw]) orelse br_result[bw]) catch return br_result; } },
                        'W' => { while (bw + 1 < bie) { br_buf.append(alloc, br_result[bw]) catch return br_result; bw += 1; br_buf.append(alloc, bool_replacements.get(br_result[bw]) orelse br_result[bw]) catch return br_result; bw += 1; } if (bw < bie) { br_buf.append(alloc, br_result[bw]) catch return br_result; bw += 1; } },
                        'E' => { while (bw < bie) { const w = br_result[bw]; bw += 1; br_buf.append(alloc, w) catch return br_result; if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (bw < bie) : (bw += 1) { br_buf.append(alloc, bool_replacements.get(br_result[bw]) orelse br_result[bw]) catch return br_result; } },
                        else => { br_buf.append(alloc, br_result[bw]) catch return br_result; bw += 1; },
                    }
                }
                while (bw < bie) : (bw += 1) { br_buf.append(alloc, br_result[bw]) catch return br_result; }
                br_out.appendSlice(alloc, br_buf.items) catch return br_result;
                br_buf.deinit(alloc);
            } else {
                br_out.appendSlice(alloc, br_result[pos..bie]) catch return br_result;
            }
            pos = bie;
        }
        alloc.free(br_result);
        return br_out.toOwnedSlice(alloc) catch {
            br_out.deinit(alloc);
            return alloc.dupe(u32, br_result);
        };
    }

    return result_owned;
}

/// Scatter-store to CompositeConstruct: For function-local vector variables
/// where all components are individually stored via AccessChain and the whole
/// vector is loaded once, replace with OpCompositeConstruct.
pub fn scatterStoreToComposite(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    var vec_sizes = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer vec_sizes.deinit(alloc);
    var array_sizes = std.AutoHashMapUnmanaged(u32, u32).empty; // array_type_id -> element_count
    defer array_sizes.deinit(alloc);
    var ptr_pointee = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer ptr_pointee.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 23 and wc >= 4) try vec_sizes.put(alloc, words[pos + 1], words[pos + 3]); // OpTypeVector
        if (opcode == 32 and wc >= 4) try ptr_pointee.put(alloc, words[pos + 1], words[pos + 3]); // OpTypePointer
        pos = ie;
    }

    // Build constant map
    var const_vals = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer const_vals.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 43 and wc >= 4) { // OpConstant
            try const_vals.put(alloc, words[pos + 2], words[pos + 3]);
        }
        if (opcode == 28 and wc >= 4) { // OpTypeArray: result_id, elem_type, length_id
            const arr_tid = words[pos + 1];
            const len_id = words[pos + 3];
            if (const_vals.get(len_id)) |len| {
                try array_sizes.put(alloc, arr_tid, len);
            }
        }
        pos = ie;
    }

    const VarInfo = struct { var_id: u32, comp_count: u32, vec_type: u32 };
    var var_infos = std.ArrayListUnmanaged(VarInfo).empty;
    defer var_infos.deinit(alloc);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 59 and wc >= 4 and words[pos + 3] == 7) {
            const ptid = ptr_pointee.get(words[pos + 1]) orelse {
                pos = ie;
                continue;
            };
            const cnt = vec_sizes.get(ptid) orelse array_sizes.get(ptid) orelse {
                pos = ie;
                continue;
            };
            try var_infos.append(alloc, .{ .var_id = words[pos + 2], .comp_count = cnt, .vec_type = ptid });
        }
        pos = ie;
    }
    if (var_infos.items.len == 0) return words;

    const Replacement = struct {
        var_id: u32,
        vec_type: u32,
        comp_count: u32,
        load_pos: u32,
        load_result: u32,
        ac_positions: std.ArrayListUnmanaged(u32),
        store_positions: std.ArrayListUnmanaged(u32),
    };
    var replacements = std.ArrayListUnmanaged(Replacement).empty;
    defer {
        for (replacements.items) |*r| {
            r.ac_positions.deinit(alloc);
            r.store_positions.deinit(alloc);
        }
        replacements.deinit(alloc);
    }

    for (var_infos.items) |vi| {
        var ac_results = std.AutoHashMapUnmanaged(u32, void).empty;
        defer ac_results.deinit(alloc);
        var ac_positions = std.ArrayListUnmanaged(u32).empty;
        defer ac_positions.deinit(alloc);
        var store_positions = std.ArrayListUnmanaged(u32).empty;
        defer store_positions.deinit(alloc);
        var load_pos: u32 = 0;
        var load_result: u32 = 0;
        var direct_stores: u32 = 0;
        var multi_loads: bool = false;

        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos];
            const wc: u32 = hdr >> 16;
            const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            const ie = pos + wc;
            if (ie > words.len) break;
            if (opcode == 65 and wc >= 5 and words[pos + 3] == vi.var_id) {
                try ac_results.put(alloc, words[pos + 2], {});
                try ac_positions.append(alloc, pos);
            }
            if (opcode == 62 and wc >= 3) {
                const tgt = words[pos + 1];
                if (ac_results.contains(tgt)) {
                    try store_positions.append(alloc, pos);
                } else if (tgt == vi.var_id) {
                    direct_stores += 1;
                }
            }
            if (opcode == 61 and wc >= 4 and words[pos + 3] == vi.var_id) {
                if (load_result == 0) {
                    load_result = words[pos + 2];
                    load_pos = pos;
                } else {
                    multi_loads = true;
                }
            }
            pos = ie;
        }

        if (direct_stores > 0 or multi_loads or load_result == 0) continue;
        if (ac_results.count() != vi.comp_count) continue;
        if (@as(u32, @intCast(store_positions.items.len)) != vi.comp_count) continue;

        var my_ac = std.ArrayListUnmanaged(u32).empty;
        var my_st = std.ArrayListUnmanaged(u32).empty;
        try my_ac.appendSlice(alloc, ac_positions.items);
        try my_st.appendSlice(alloc, store_positions.items);
        try replacements.append(alloc, .{
            .var_id = vi.var_id,
            .vec_type = vi.vec_type,
            .comp_count = vi.comp_count,
            .load_pos = load_pos,
            .load_result = load_result,
            .ac_positions = my_ac,
            .store_positions = my_st,
        });
    }
    if (replacements.items.len == 0) return words;

    var remove_set = std.DynamicBitSet.initEmpty(alloc, words.len) catch return words;
    defer remove_set.deinit();

    const CompRep = struct { load_pos: u32, vec_type: u32, load_result: u32, comp_vals: []u32 };
    var comp_reps = std.ArrayListUnmanaged(CompRep).empty;
    defer {
        for (comp_reps.items) |cr| alloc.free(cr.comp_vals);
        comp_reps.deinit(alloc);
    }

for (replacements.items, 0..) |rep, rep_idx| {
        _ = rep_idx;
        outer: {
        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos];
            const wc: u32 = hdr >> 16;
            if (wc == 0) break;
            const ie = pos + wc;
            if (ie > words.len) break;
            const op: u16 = @truncate(hdr & 0xFFFF);
            if (op == 59 and wc >= 4 and words[pos + 2] == rep.var_id) {
                remove_set.set(pos);
            }
            pos = ie;
        }
        for (rep.ac_positions.items) |p| remove_set.set(p);
        for (rep.store_positions.items) |p| remove_set.set(p);

        var comp_vals = try alloc.alloc(u32, rep.comp_count);
        @memset(comp_vals, 0);
        for (rep.ac_positions.items) |ac_pos| {
            const ac_res = words[ac_pos + 2];
            const ac_idx_id = words[ac_pos + 4];
            const ac_idx = const_vals.get(ac_idx_id) orelse {
                // Non-constant index — skip this variable
                break :outer;
            };
            for (rep.store_positions.items) |sp| {
                if (words[sp + 1] == ac_res and ac_idx < rep.comp_count) {
                    comp_vals[ac_idx] = words[sp + 2];
                    break;
                }
            }
        }
        try comp_reps.append(alloc, .{
            .load_pos = rep.load_pos,
            .vec_type = rep.vec_type,
            .load_result = rep.load_result,
            .comp_vals = comp_vals,
        });
        }
    }

    var load_map = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer load_map.deinit(alloc);
    for (comp_reps.items, 0..) |cr, i| {
        try load_map.put(alloc, cr.load_pos, @intCast(i));
    }

    var out = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    out.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (remove_set.isSet(pos)) {
            pos = ie;
            continue;
        }

        if (load_map.get(pos)) |cr_idx| {
            const cr = comp_reps.items[cr_idx];
            const new_wc: u32 = @intCast(3 + cr.comp_vals.len);
            out.append(alloc, (new_wc << 16) | 80) catch return words;
            out.append(alloc, cr.vec_type) catch return words;
            out.append(alloc, cr.load_result) catch return words;
            for (cr.comp_vals) |v| out.append(alloc, v) catch return words;
            pos = ie;
            continue;
        }

        out.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    const nw = out.toOwnedSlice(alloc) catch return words;
    const dced = deadCodeElim(alloc, nw) catch return nw;
    if (dced.ptr != nw.ptr) alloc.free(nw);
    const compacted = compact_ids.compactIds(alloc, dced) catch return dced;
    if (compacted.ptr != dced.ptr) alloc.free(dced);
    return compacted;
}

/// Store-forward extract: when a function-local variable is stored once (whole value)
/// and then only read via AccessChain + Load (member reads, no whole-variable loads),
/// replace each AC+Load with OpCompositeExtract from the stored value directly.
/// This eliminates the OpVariable, OpStore, and all AccessChains.
pub fn storeForwardExtract(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Build constant map for resolving AC index IDs
    var const_vals = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer const_vals.deinit(alloc);
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 43 and wc >= 4) { // OpConstant
            try const_vals.put(alloc, words[pos + 2], words[pos + 3]);
        }
        pos = ie;
    }

    // Find function-local variables (any type)
    var func_var_set = std.AutoHashMapUnmanaged(u32, void).empty;
    defer func_var_set.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 59 and wc >= 4 and words[pos + 3] == 7) { // OpVariable Function SC
            const var_id = words[pos + 2];
            if (var_id < bound) try func_var_set.put(alloc, var_id, {});
        }
        pos = ie;
    }
    if (func_var_set.count() == 0) return words;

    // Analyze each variable's usage
    const MemberRead = struct { ac_id: u32, ac_idx: u32, load_result: u32, load_type: u32 };
    const VarAnalysis = struct {
        var_id: u32,
        stored_val: u32,
        member_reads: std.ArrayListUnmanaged(MemberRead),
        ac_positions: std.ArrayListUnmanaged(u32),
        store_pos: u32,
        var_pos: u32,
    };
    var analyses = std.ArrayListUnmanaged(VarAnalysis).empty;
    defer {
        for (analyses.items) |*a| {
            a.member_reads.deinit(alloc);
            a.ac_positions.deinit(alloc);
        }
        analyses.deinit(alloc);
    }

    var fit = func_var_set.iterator();
    while (fit.next()) |entry| {
        const var_id = entry.key_ptr.*;
        var direct_stores: u32 = 0;
        var stored_val: u32 = 0;
        var store_pos: u32 = 0;
        var var_pos: u32 = 0;
        var whole_loads: u32 = 0;

        // Track AC results into this var
        var ac_to_var = std.AutoHashMapUnmanaged(u32, void).empty;
        defer ac_to_var.deinit(alloc);
        var ac_positions = std.ArrayListUnmanaged(u32).empty;
        defer ac_positions.deinit(alloc);

        // Track loads from AC results: load_result -> (ac_result, ac_index, load_type)
        var member_reads = std.ArrayListUnmanaged(MemberRead).empty;
        defer member_reads.deinit(alloc);

        // Also track if any AC result is used in something other than a load (e.g., store target)
        var ac_non_load_use: bool = false;

        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos];
            const wc: u32 = hdr >> 16;
            const opcode: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break;
            const ie = pos + wc;
            if (ie > words.len) break;

            if (opcode == 59 and wc >= 4 and words[pos + 2] == var_id) {
                var_pos = pos;
            }

            // Direct store to var
            if (opcode == 62 and wc >= 3 and words[pos + 1] == var_id) {
                direct_stores += 1;
                stored_val = words[pos + 2];
                store_pos = pos;
            }

            // Whole load of var
            if (opcode == 61 and wc >= 4 and words[pos + 3] == var_id) {
                whole_loads += 1;
            }

            // AccessChain into var (any number of indices — merged ACs may have wc > 5)
            // Track all ACs, but also flag multi-index ACs for disqualification
            if (opcode == 65 and wc >= 5 and words[pos + 3] == var_id) {
                try ac_to_var.put(alloc, words[pos + 2], {});
                try ac_positions.append(alloc, pos);
                // Multi-index ACs (merged by mergeAccessChains) access nested struct members.
                // The replacement logic only handles single-index ACs, so disqualify.
                if (wc > 5) {
                    ac_non_load_use = true;
                }
            }

            // Store to an AC result of this var (disqualify)
            if (opcode == 62 and wc >= 3 and ac_to_var.contains(words[pos + 1])) {
                ac_non_load_use = true;
            }

            // AccessChain where the base is an AC result of this var (nested AC — disqualify)
            // This handles patterns like: struct { Material mat; } s; s.mat.roughness
            // where AccessChain(s, 2) gives a Material ptr, then AccessChain(mat_ptr, 1) gives float ptr
            if (opcode == 65 and wc >= 5 and ac_to_var.contains(words[pos + 3])) {
                ac_non_load_use = true;
            }

            // Load from AC result
            if (opcode == 61 and wc >= 4 and ac_to_var.contains(words[pos + 3])) {
                const load_result = words[pos + 2];
                const load_type = words[pos + 1];
                const ac_id = words[pos + 3];
                // Find the AC instruction to get the index
                const ac_idx = blk: {
                    var p: u32 = 5;
                    while (p < words.len) {
                        const h = words[p];
                        const w = h >> 16;
                        const op: u16 = @truncate(h & 0xFFFF);
                        if (w == 0) break;
                        const e = p + w;
                        if (e > words.len) break;
                        if (op == 65 and w >= 5 and words[p + 2] == ac_id) {
                            const idx_id = words[p + 4];
                            break :blk const_vals.get(idx_id) orelse 0xFFFF_FFFF;
                        }
                        p = e;
                    }
                    break :blk 0xFFFF_FFFF;
                };
                if (ac_idx != 0xFFFF_FFFF) {
                    try member_reads.append(alloc, .{ .ac_id = ac_id, .ac_idx = ac_idx, .load_result = load_result, .load_type = load_type });
                }
            }

            pos = ie;
        }

        // Qualify: exactly 1 direct store, 0 whole loads, all AC results are only loaded, no non-load AC use
        if (direct_stores == 1 and whole_loads == 0 and !ac_non_load_use and member_reads.items.len > 0) {
            // Dominance check: store must dominate all loads.
            // Build a map from position -> block label by scanning for OpLabel instructions.
            // Then verify that store and load positions are in the same block.
            const store_block_id = blk: {
                var bp: u32 = 5;
                var cur: u32 = 0;
                while (bp < words.len) {
                    if (bp == store_pos) break :blk cur;
                    const bh = words[bp]; const bwc: u32 = bh >> 16;
                    if (bwc == 0) break;
                    const bop: u16 = @truncate(bh & 0xFFFF);
                    if (bop == 248 and bwc >= 2) cur = words[bp + 1]; // OpLabel
                    const bie = bp + bwc;
                    if (bie > words.len) break;
                    bp = bie;
                }
                break :blk cur;
            };
            var same_block = true;
            for (member_reads.items) |mr| {
                const load_block_id = blk: {
                    var bp: u32 = 5;
                    var cur: u32 = 0;
                    while (bp < words.len) {
                        const bh = words[bp]; const bwc: u32 = bh >> 16;
                        if (bwc == 0) break;
                        const bop: u16 = @truncate(bh & 0xFFFF);
                        if (bop == 248 and bwc >= 2) cur = words[bp + 1]; // OpLabel
                        if (bop == 61 and bwc >= 4 and words[bp + 2] == mr.load_result) break :blk cur;
                        const bie = bp + bwc;
                        if (bie > words.len) break;
                        bp = bie;
                    }
                    break :blk cur;
                };
                if (load_block_id != store_block_id) { same_block = false; break; }
            }
            if (!same_block) continue;
            // Verify: every AC result is accounted for (loaded with known index)
            var all_ac_loaded = true;
            var aci = ac_to_var.iterator();
            while (aci.next()) |ae| {
                const ac_res = ae.key_ptr.*;
                var found = false;
                for (member_reads.items) |mr| {
                    if (mr.ac_id == ac_res) { found = true; break; }
                }
                if (!found) { all_ac_loaded = false; break; }
            }
            if (!all_ac_loaded) continue;

            // Copy positions and member reads
            var my_ac_pos = std.ArrayListUnmanaged(u32).empty;
            try my_ac_pos.appendSlice(alloc, ac_positions.items);
            var my_reads = std.ArrayListUnmanaged(MemberRead).empty;
            try my_reads.appendSlice(alloc, member_reads.items);

            try analyses.append(alloc, .{
                .var_id = var_id,
                .stored_val = stored_val,
                .member_reads = my_reads,
                .ac_positions = my_ac_pos,
                .store_pos = store_pos,
                .var_pos = var_pos,
            });
        }
    }
    if (analyses.items.len == 0) return words;

    // Build removal set and replacement map
    var remove_set = std.DynamicBitSet.initEmpty(alloc, words.len) catch return words;
    defer remove_set.deinit();

    const Extract = struct { load_result: u32, load_type: u32, stored_val: u32, ac_idx: u32 };
    var extracts = std.ArrayListUnmanaged(Extract).empty;
    defer extracts.deinit(alloc);

    // Map: load_result -> extracts index
    var load_result_map = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer load_result_map.deinit(alloc);

    for (analyses.items) |a| {
        remove_set.set(a.var_pos);
        remove_set.set(a.store_pos);
        for (a.ac_positions.items) |p| remove_set.set(p);
        for (a.member_reads.items) |mr| {
            try extracts.append(alloc, .{
                .load_result = mr.load_result,
                .load_type = mr.load_type,
                .stored_val = a.stored_val,
                .ac_idx = mr.ac_idx,
            });
            try load_result_map.put(alloc, mr.load_result, @intCast(extracts.items.len - 1));
        }
    }

    // Build set of load positions to remove (we'll replace the load with extract)
    // We need to find the load instruction position for each member read
    var load_positions = std.AutoHashMapUnmanaged(u32, u32).empty; // load_result -> load_pos
    defer load_positions.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 61 and wc >= 4) { // OpLoad
            const result_id = words[pos + 2];
            if (load_result_map.contains(result_id)) {
                try load_positions.put(alloc, result_id, pos);
            }
        }
        pos = ie;
    }

    // Rewrite
    var out = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    out.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (remove_set.isSet(pos)) {
            pos = ie;
            continue;
        }

        // Check if this is an OpLoad we should replace with OpCompositeExtract
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (opcode == 61 and wc >= 4) { // OpLoad
            const result_id = words[pos + 2];
            if (load_result_map.get(result_id)) |ext_idx| {
                const ext = extracts.items[ext_idx];
                // OpCompositeExtract: type, result, composite, index
                out.append(alloc, (5 << 16) | 81) catch return words; // opcode 81 = OpCompositeExtract
                out.append(alloc, ext.load_type) catch return words;
                out.append(alloc, ext.load_result) catch return words;
                out.append(alloc, ext.stored_val) catch return words;
                out.append(alloc, ext.ac_idx) catch return words;
                pos = ie;
                continue;
            }
        }

        out.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    const nw = out.toOwnedSlice(alloc) catch return words;
    const dced = deadCodeElim(alloc, nw) catch return nw;
    if (dced.ptr != nw.ptr) alloc.free(nw);
    const compacted = compact_ids.compactIds(alloc, dced) catch return dced;
    if (compacted.ptr != dced.ptr) alloc.free(dced);
    return compacted;
}

/// Eliminate trivial entry point wrappers: when the entry point function
/// just calls another function (and returns its result or returns void),
/// redirect the entry point to the callee and remove the wrapper.
pub fn elimTrivialEntryPoint(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Find OpEntryPoint to get the entry function ID
    var entry_func_id: u32 = 0;
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 15 and wc >= 3) { // OpEntryPoint
            entry_func_id = words[pos + 2];
            break;
        }
        pos = ie;
    }
    if (entry_func_id == 0) return words;

    // Find the entry point function body
    // Scan for: OpFunction(entry), OpLabel, [optional], OpFunctionCall, OpReturn/OpReturnValue, OpFunctionEnd
    var func_start: u32 = 0;
    var func_end: u32 = 0;
    var callee_id: u32 = 0;
    var call_has_result: bool = false; // true if the call produces a result used in ReturnValue

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 54 and wc >= 4 and words[pos + 2] == entry_func_id) {
            func_start = pos;
            // Scan function body
            var inner: u32 = ie;
            var instr_count: u32 = 0;
            var has_call: bool = false;
            var has_store: bool = false;
            var has_branch: bool = false;
            var local_callee: u32 = 0;
            var local_call_result: u32 = 0;
            var local_call_has_result: bool = false;
            var return_pos: u32 = 0;

            while (inner < words.len) {
                const ihdr = words[inner]; const iwc: u32 = ihdr >> 16; const iop: u16 = @truncate(ihdr & 0xFFFF);
                if (iwc == 0) break;
                const iie = inner + iwc;
                if (iie > words.len) break;
                if (iop == 56) { // OpFunctionEnd
                    func_end = iie;
                    break;
                }
                instr_count += 1;
                if (iop == 57) { // OpFunctionCall
                    has_call = true;
                    local_callee = words[inner + 3]; // func arg is at pos+3 for fixed=2 layout: type, result, func
                    if (iwc >= 4 and words[inner + 2] != 0) {
                        local_call_has_result = true;
                        local_call_result = words[inner + 2];
                    }
                }
                if (iop == 62) has_store = true; // OpStore
                if (iop == 249 or iop == 250) has_branch = true; // OpBranch/OpBranchConditional
                if (iop == 253) { // OpReturn
                    return_pos = inner;
                }
                if (iop == 254) { // OpReturnValue
                    return_pos = inner;
                    // Check if return value is the call result
                    if (local_call_has_result and iwc >= 2 and words[inner + 1] == local_call_result) {
                        // Good - returning the call's result directly
                    } else {
                        // Returning something else - can't inline trivially
                        has_store = true; // treat as non-trivial
                    }
                }
                inner = iie;
            }

            // Qualify: must be simple (label + call + return, no stores, no branches)
            // Allow: Label, FunctionCall, Return (void or returning call result)
            // instr_count includes Label, FunctionCall, Return/ReturnValue = 3
            if (has_call and !has_store and !has_branch and instr_count <= 4) {
                callee_id = local_callee;
                call_has_result = local_call_has_result;
            }
            break;
        }
        pos = ie;
    }

    if (callee_id == 0 or func_start == 0 or func_end == 0) return words;
    if (callee_id == entry_func_id) return words; // no recursion

    // Verify callee return type matches entry return type
    var entry_return_type: u32 = 0;
    var callee_return_type: u32 = 0;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 54 and wc >= 4) {
            if (words[pos + 2] == entry_func_id) entry_return_type = words[pos + 1];
            if (words[pos + 2] == callee_id) callee_return_type = words[pos + 1];
        }
        pos = ie;
    }
    if (entry_return_type != callee_return_type) return words;

    // Verify function call has no arguments beyond the callee
    // Find the call instruction in the entry function
    pos = func_start;
    while (pos < func_end) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > func_end) break;
        if (opcode == 57) { // OpFunctionCall
            // fixed=2: result_type(1), result(2), func(3), args(4..)
            if (wc > 4) return words; // has arguments
        }
        pos = ie;
    }

    // Rewrite: replace entry_func_id with callee_id everywhere, remove wrapper function
    var out = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    out.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip the wrapper function entirely
        if (pos >= func_start and pos < func_end) {
            pos = ie;
            continue;
        }

        // Replace entry_func_id -> callee_id in OpEntryPoint
        if (opcode == 15 and wc >= 3 and words[pos + 2] == entry_func_id) {
            try out.appendSlice(alloc, words[pos .. pos + 2]);
            try out.append(alloc, callee_id);
            try out.appendSlice(alloc, words[pos + 3 .. ie]);
            pos = ie;
            continue;
        }

        // Replace in OpExecutionMode / OpExecutionModeId
        if ((opcode == 16 or opcode == 531) and wc >= 3 and words[pos + 1] == entry_func_id) {
            try out.append(alloc, hdr);
            try out.append(alloc, callee_id);
            try out.appendSlice(alloc, words[pos + 2 .. ie]);
            pos = ie;
            continue;
        }

        // Skip OpName for entry function (to avoid name conflict)
        if (opcode == 5 and wc >= 3 and words[pos + 1] == entry_func_id) {
            pos = ie;
            continue;
        }

        // Skip OpTypeFunction for the entry function's type if it becomes dead
        // (DCE will handle this)

        try out.appendSlice(alloc, words[pos..ie]);
        pos = ie;
    }

    if (out.items.len == words.len) {
        out.deinit(alloc);
        return words;
    }
    const nw = out.toOwnedSlice(alloc) catch return words;
    const dced = deadCodeElim(alloc, nw) catch return nw;
    if (dced.ptr != nw.ptr) alloc.free(nw);
    const compacted = compact_ids.compactIds(alloc, dced) catch return dced;
    if (compacted.ptr != dced.ptr) alloc.free(dced);
    return compacted;
}

/// Eliminate identity vector shuffles: OpVectorShuffle(v, v, 0, 1, ..., N-1)
/// These produce the same vector, so all uses of the result can be replaced with v.
pub fn elimIdentityShuffle(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 0: Build type map for verifying identity shuffles
    // Map: result_id -> result_type_id for vector ops
    var type_map = std.AutoHashMapUnmanaged(u32, u32).empty; // id -> type_id
    defer type_map.deinit(alloc);
    var tpos: u32 = 5;
    while (tpos < words.len) {
        const thdr = words[tpos];
        const twc: u32 = thdr >> 16;
        const top: u16 = @truncate(thdr & 0xFFFF);
        if (twc == 0) break;
        const tie = tpos + twc;
        if (tie > words.len) break;
        if (twc >= 4) {
            const tinfo = compact_ids.getOpInfo(top) orelse {
                tpos = tie;
                continue;
            };
            if (tinfo.fixed == 2) {
                type_map.put(alloc, words[tpos + 2], words[tpos + 1]) catch return words;
            }
        }
        tpos = tie;
    }

    // Phase 1: Find identity shuffles (same vec twice, indices = 0,1,...,N-1, same type)
    var sub_map = std.AutoHashMapUnmanaged(u32, u32).empty; // shuffle_result -> source_vec
    defer sub_map.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 79 and wc >= 6) { // OpVectorShuffle
            const shuffle_type = words[pos + 1];
            const result_id = words[pos + 2];
            const vec1 = words[pos + 3];
            const vec2 = words[pos + 4];
            if (vec1 == vec2) {
                // Check if indices are 0, 1, ..., N-1
                const num_indices = wc - 5;
                var is_identity = true;
                var i: u32 = 0;
                while (i < num_indices) : (i += 1) {
                    if (words[pos + 5 + i] != i) {
                        is_identity = false;
                        break;
                    }
                }
                // Verify shuffle result type matches source vector type
                if (is_identity) {
                    const src_type = type_map.get(vec1) orelse 0;
                    if (src_type != shuffle_type) is_identity = false;
                }
                if (is_identity) {
                    try sub_map.put(alloc, result_id, vec1);
                }
            }
        }
        pos = ie;
    }

    if (sub_map.count() == 0) return words;

    // Resolve transitive substitutions
    var changed = true;
    while (changed) {
        changed = false;
        var it = sub_map.iterator();
        while (it.next()) |entry| {
            if (sub_map.get(entry.value_ptr.*)) |resolved| {
                entry.value_ptr.* = resolved;
                changed = true;
            }
        }
    }

    // Phase 2: Rewrite - replace all uses and remove identity shuffles
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip identity shuffle instructions
        if (opcode == 79 and wc >= 6) {
            const result_id = words[pos + 2];
            if (sub_map.contains(result_id)) {
                pos = ie;
                continue;
            }
        }

        // Apply substitution to all operands
        const info = compact_ids.getOpInfo(opcode) orelse {
            result.append(alloc, hdr) catch return words;
            var wi: u32 = pos + 1;
            while (wi < ie) : (wi += 1) {
                result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
            }
            pos = ie;
            continue;
        };

        result.append(alloc, hdr) catch return words;
        var wi: u32 = pos + 1;
        switch (info.fixed) {
            0 => {},
            1 => { if (wi < ie) { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; } },
            2 => {
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                if (wi < ie) { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; }
            },
            3 => { if (wi < ie) { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; },
                'l' => { result.append(alloc, words[wi]) catch return words; wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; },
                'L', 's' => { while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words; },
                'M' => { if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; },
                'W' => { while (wi + 1 < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; wi += 1; } if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } },
                'E' => { while (wi < ie) { const w = words[wi]; wi += 1; result.append(alloc, w) catch return words; if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break; } while (wi < ie) : (wi += 1) result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words; },
                else => { result.append(alloc, words[wi]) catch return words; wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words;
        pos = ie;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }
    const nw = result.toOwnedSlice(alloc) catch return words;
    const dced = deadCodeElim(alloc, nw) catch return nw;
    if (dced.ptr != nw.ptr) alloc.free(nw);
    const compacted = compact_ids.compactIds(alloc, dced) catch return dced;
    if (compacted.ptr != dced.ptr) alloc.free(dced);
    return compacted;
}

pub fn foldShuffleFromComposite(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build map of CompositeConstruct (80) and ConstantComposite (44): result_id -> []constituent_ids
    var cc_map = std.AutoHashMapUnmanaged(u32, []const u32).empty;
    defer {
        var it = cc_map.iterator();
        while (it.next()) |entry| alloc.free(entry.value_ptr.*);
        cc_map.deinit(alloc);
    }

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if ((opcode == 80 or opcode == 44) and wc >= 4) {
            const result_id = words[pos + 2];
            const constituents = words[pos + 3 .. ie];
            const copy = try alloc.dupe(u32, constituents);
            try cc_map.put(alloc, result_id, copy);
        }
        pos = ie;
    }

    if (cc_map.count() == 0) return words;

    // Phase 2: Find VectorShuffle where vec1 is a known composite and all indices select from vec1
    var shuffle_fwd = std.AutoHashMapUnmanaged(u32, []const u32).empty;
    defer {
        var it2 = shuffle_fwd.iterator();
        while (it2.next()) |entry| alloc.free(entry.value_ptr.*);
        shuffle_fwd.deinit(alloc);
    }

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 79 and wc >= 6) { // OpVectorShuffle
            const result_id = words[pos + 2];
            const vec1 = words[pos + 3];
            const indices = words[pos + 5 .. ie];

            const vec1_constituents = cc_map.get(vec1);
            if (vec1_constituents) |cs| {
                var all_from_vec1 = true;
                for (indices) |idx| {
                    if (idx >= cs.len) {
                        all_from_vec1 = false;
                        break;
                    }
                }

                if (all_from_vec1 and indices.len > 0) {
                    var new_constituents = std.ArrayListUnmanaged(u32).empty;
                    for (indices) |idx| {
                        try new_constituents.append(alloc, cs[idx]);
                    }
                    const cs_slice = try new_constituents.toOwnedSlice(alloc);
                    try shuffle_fwd.put(alloc, result_id, cs_slice);
                }
            }
        }
        pos = ie;
    }

    if (shuffle_fwd.count() == 0) return words;

    // Phase 3: Replace qualifying shuffles with CompositeConstruct
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 79 and wc >= 6) {
            const result_id = words[pos + 2];
            if (shuffle_fwd.get(result_id)) |new_cs| {
                const result_type = words[pos + 1];
                const cc_wc: u32 = 3 + @as(u32, @intCast(new_cs.len));
                try result.append(alloc, (cc_wc << 16) | 80); // OpCompositeConstruct
                try result.append(alloc, result_type);
                try result.append(alloc, result_id);
                for (new_cs) |c| try result.append(alloc, c);
                pos = ie;
                continue;
            }
        }

        try result.appendSlice(alloc, words[pos..ie]);
        pos = ie;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }
    return result.toOwnedSlice(alloc) catch return words;
}

pub fn elimDeadVoidCalls(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find void type IDs
    var void_types = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer void_types.deinit();
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 19 and wc >= 2) {
            const tid = words[pos + 1];
            if (tid < bound) void_types.set(tid);
        }
        pos = ie;
    }

    // Phase 2: Find pure functions (no stores, no calls, no atomics/barriers)
    var pure_funcs = std.AutoHashMapUnmanaged(u32, void).empty;
    defer pure_funcs.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 54 and wc >= 5) { // OpFunction
            const func_id = words[pos + 2];
            var has_side_effect = false;
            var fp = ie;
            while (fp < words.len) {
                const fh = words[fp]; const fwc: u32 = fh >> 16; const fop: u16 = @truncate(fh & 0xFFFF);
                if (fwc == 0) break;
                const fie = fp + fwc;
                if (fie > words.len) break;
                if (fop == 56) break;
                if (fop == 62) has_side_effect = true; // OpStore
                if (fop == 57) has_side_effect = true; // OpFunctionCall
                if (fop == 236) has_side_effect = true; // OpControlBarrier
                if (fop >= 237 and fop <= 244) has_side_effect = true; // OpAtomic*
                if (fop >= 378 and fop <= 385) has_side_effect = true;
                if (fop == 218 or fop == 219) has_side_effect = true; // OpEmitVertex, OpEndPrimitive
                fp = fie;
            }
            if (!has_side_effect) try pure_funcs.put(alloc, func_id, {});
        }
        pos = ie;
    }
    if (pure_funcs.count() == 0) return words;

    // Phase 3: Find void-returning calls to pure functions
    // Only remove the call, not the function definition (callee might be an entry point)
    var dead_calls = std.AutoHashMapUnmanaged(u32, void).empty; // position -> void
    defer dead_calls.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 57 and wc >= 5) { // OpFunctionCall
            const result_type = words[pos + 1];
            const called_func = words[pos + 3];
            if (result_type < bound and void_types.isSet(result_type) and pure_funcs.contains(called_func)) {
                try dead_calls.put(alloc, pos, {});
            }
        }
        pos = ie;
    }
    if (dead_calls.count() == 0) return words;

    // Phase 5: Rewrite - only remove dead calls
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (dead_calls.contains(pos)) { pos = ie; continue; }
        result.appendSliceAssumeCapacity(words[pos..ie]);
        pos = ie;
    }
    return result.toOwnedSlice(alloc) catch return words;
}

/// Remove stores to function-local variables that have no loads.
/// After store forwarding, some vars may have stores but no loads — those stores are dead.
pub fn elimDeadVarStores(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find function-local variable IDs (storage class 7)
    var func_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer func_vars.deinit();
    var pos: u32 = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 59 and wc >= 4) { // OpVariable
            const sc = words[pos + 3];
            if (sc == 6) { // Private storage class only (NOT Output — those are shader outputs that must be preserved)
                const rid = words[pos + 2];
                if (rid < bound) func_vars.set(rid);
            }
        }
        pos = ie;
    }
    if (func_vars.count() == 0) return words;

    // Phase 2: Count loads and stores per function-local var
    var has_load = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer has_load.deinit();
    var has_store = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer has_store.deinit();
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 62 and wc >= 3) { // OpStore
            const ptr = words[pos + 1];
            if (ptr < bound and func_vars.isSet(ptr)) has_store.set(ptr);
        }
        if (opcode == 61 and wc >= 4) { // OpLoad
            const ptr = words[pos + 3];
            if (ptr < bound and func_vars.isSet(ptr)) has_load.set(ptr);
        }
        // Also check AccessChain bases (if var is used as AC base, it's accessed)
        if (opcode == 65 and wc >= 4) { // OpAccessChain
            const base = words[pos + 3];
            if (base < bound and func_vars.isSet(base)) has_load.set(base);
        }
        pos = ie;
    }

    // Phase 3: Find vars with stores but no loads
    var dead_store_vars = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer dead_store_vars.deinit();
    var it = func_vars.iterator(.{});
    while (it.next()) |var_id| {
        if (has_store.isSet(var_id) and !has_load.isSet(var_id)) {
            dead_store_vars.set(var_id);
        }
    }
    if (dead_store_vars.count() == 0) return words;

    // Phase 4: Remove stores to dead vars
    var result2 = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result2.appendSliceAssumeCapacity(words[0..5]);
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        // Skip OpStore to dead vars
        if (opcode == 62 and wc >= 3) { // OpStore
            const ptr = words[pos + 1];
            if (ptr < bound and dead_store_vars.isSet(ptr)) { pos = ie; continue; }
        }
        result2.appendSliceAssumeCapacity(words[pos..ie]);
        pos = ie;
    }
    return result2.toOwnedSlice(alloc) catch return words;
}

/// Replace OpLoad + OpStore (where load result is used only in the store) with OpCopyMemory.
/// This saves 1 ID per copy (the load result ID is eliminated).
pub fn copyMemoryOpt(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find OpLoad instructions whose result is used exactly once in an OpStore
    var load_info = std.AutoHashMapUnmanaged(u32, struct { pos: u32, src_ptr: u32, store_pos: u32, dst_ptr: u32 }).empty;
    defer load_info.deinit(alloc);

    // First pass: collect load result IDs and their usage count
    var load_positions = std.AutoHashMapUnmanaged(u32, u32).empty; // result_id -> pos
    defer load_positions.deinit(alloc);
    var use_count = std.AutoHashMapUnmanaged(u32, u32).empty; // result_id -> count
    defer use_count.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 61 and wc >= 4) { // OpLoad
            const rid = words[pos + 2];
            if (rid > 0 and rid < bound) {
                try load_positions.put(alloc, rid, pos);
                try use_count.put(alloc, rid, 0);
            }
        }
        pos = ie;
    }

    if (load_positions.count() == 0) return words;

    // Count uses of each load result (excluding the OpLoad instruction itself)
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        // Skip OpLoad instructions (we don't count the definition as a use)
        if (opcode != 61) {
            const info = compact_ids.getOpInfo(opcode) orelse {
                // Unknown opcode: conservatively count all operands
                var wi2: u32 = pos + 1;
                while (wi2 < ie) : (wi2 += 1) {
                    if (words[wi2] > 0 and words[wi2] < bound) {
                        if (use_count.getPtr(words[wi2])) |cnt| cnt.* += 1;
                    }
                }
                pos = ie;
                continue;
            };
            var wi: u32 = pos + 1;
            // Skip fixed operands
            switch (info.fixed) {
                1 => { wi += 1; },
                2 => { wi += 2; },
                3 => { wi += 1; },
                else => {},
            }
            // Process variable operands using getOpInfo
            for (info.ops) |ch| {
                if (wi >= ie) break;
                switch (ch) {
                    'i' => {
                        if (words[wi] > 0 and words[wi] < bound) {
                            if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                        }
                        wi += 1;
                    },
                    'I' => { while (wi < ie) : (wi += 1) {
                        if (words[wi] > 0 and words[wi] < bound) {
                            if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                        }
                    }},
                    'l' => { wi += 1; },
                    'L' => { wi = ie; },
                    's' => { wi = ie; },
                    'M' => { if (wi < ie) { wi += 1; while (wi < ie) : (wi += 1) {
                        if (words[wi] > 0 and words[wi] < bound) {
                            if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                        }
                    }}},
                    'W' => { while (wi + 1 < ie) { wi += 1; if (words[wi] > 0 and words[wi] < bound) {
                        if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                    } wi += 1; } if (wi < ie) wi += 1; },
                    'E' => { while (wi < ie) { const ww = words[wi]; wi += 1; if ((ww & 0xFF) == 0 or ((ww >> 8) & 0xFF) == 0 or ((ww >> 16) & 0xFF) == 0 or ((ww >> 24) & 0xFF) == 0) break; } while (wi < ie) : (wi += 1) {
                        if (words[wi] > 0 and words[wi] < bound) {
                            if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                        }
                    }},
                    else => { wi += 1; },
                }
            }
        }
        pos = ie;
    }

    // Phase 2: Find loads used exactly once, and that use is in an OpStore
    // Build a map: store_pos -> (load_pos, src_ptr, dst_ptr)
    var replacements = std.AutoHashMapUnmanaged(u32, struct { load_pos: u32, src_ptr: u32 }).empty; // store_pos -> load_info
    defer replacements.deinit(alloc);
    var dead_loads = std.AutoHashMapUnmanaged(u32, void).empty; // load pos to skip
    defer dead_loads.deinit(alloc);

    // For each load with exactly 1 use, find the OpStore that uses it
    var li = load_positions.iterator();
    while (li.next()) |entry| {
        const rid = entry.key_ptr.*;
        const lpos = entry.value_ptr.*;
        const cnt = use_count.get(rid) orelse 0;
        if (cnt != 1) continue;

        const src_ptr = words[lpos + 3]; // OpLoad: type, result, ptr

        // Check if src_ptr was modified between the initial store and the load
        // by an AccessChain+Store pattern (e.g., v.x = expr modifies v)
        // Also check if any variable is modified via AC+Store (copyMemoryOpt is only
        // safe when both src and dst pointers are unmodified between store and load)
        var src_modified_by_ac = false;
        var ac_results_src = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
        defer ac_results_src.deinit();
        pos = 5;
        while (pos < words.len) {
            const wc_ac: u32 = words[pos] >> 16;
            const op_ac: u16 = @truncate(words[pos] & 0xFFFF);
            if (wc_ac == 0) break;
            const ie_ac = pos + wc_ac;
            if (ie_ac > words.len) break;
            if (op_ac == 65 and wc_ac >= 4 and words[pos + 3] == src_ptr) { // AccessChain base=src_ptr
                const ac_rid = words[pos + 2];
                if (ac_rid > 0 and ac_rid < bound) ac_results_src.set(ac_rid);
            }
            pos = ie_ac;
        }
        pos = 5;
        while (pos < words.len) {
            const wc_s: u32 = words[pos] >> 16;
            const op_s: u16 = @truncate(words[pos] & 0xFFFF);
            if (wc_s == 0) break;
            const ie_s = pos + wc_s;
            if (ie_s > words.len) break;
            if (op_s == 62 and wc_s >= 2) { // OpStore
                const store_target = words[pos + 1];
                if (store_target > 0 and store_target < bound and ac_results_src.isSet(store_target)) {
                    src_modified_by_ac = true;
                    break;
                }
            }
            pos = ie_s;
        }
        if (src_modified_by_ac) continue;

        // Find the OpStore that uses this value
        // NOTE: pos is reused from outer scope
        pos = 5;
        while (pos < words.len) {
            const wc2: u32 = words[pos] >> 16;
            const opcode2: u16 = @truncate(words[pos] & 0xFFFF);
            if (wc2 == 0) break;
            const ie2 = pos + wc2;
            if (ie2 > words.len) break;
            if (opcode2 == 62 and wc2 >= 3) { // OpStore
                const dst_ptr = words[pos + 1];
                const stored_val = words[pos + 2];
                if (stored_val == rid) {
                    // Don't replace self-copies (Load(X) -> Store(X))
                    if (dst_ptr == src_ptr) break;

                    // Also check: don't replace if dst_ptr has AC+Store children
                    // (the stored value was computed from a modified variable)
                    var dst_has_ac_stores = false;
                    var ac_results_dst = std.DynamicBitSet.initEmpty(alloc, bound) catch break;
                    defer ac_results_dst.deinit();
                    var p3: u32 = 5;
                    while (p3 < words.len) {
                        const wc3: u32 = words[p3] >> 16;
                        const op3: u16 = @truncate(words[p3] & 0xFFFF);
                        if (wc3 == 0) break;
                        const ie3 = p3 + wc3;
                        if (ie3 > words.len) break;
                        if (op3 == 65 and wc3 >= 4 and words[p3 + 3] == dst_ptr) {
                            const ac_rid3 = words[p3 + 2];
                            if (ac_rid3 > 0 and ac_rid3 < bound) ac_results_dst.set(ac_rid3);
                        }
                        p3 = ie3;
                    }
                    p3 = 5;
                    while (p3 < words.len) {
                        const wc4: u32 = words[p3] >> 16;
                        const op4: u16 = @truncate(words[p3] & 0xFFFF);
                        if (wc4 == 0) break;
                        const ie4 = p3 + wc4;
                        if (ie4 > words.len) break;
                        if (op4 == 62 and wc4 >= 2) {
                            const st4 = words[p3 + 1];
                            if (st4 > 0 and st4 < bound and ac_results_dst.isSet(st4)) {
                                dst_has_ac_stores = true;
                                break;
                            }
                        }
                        p3 = ie4;
                    }
                    if (dst_has_ac_stores) break;

                    // Also reject if dst is an AC result (CopyMemory to AC result
                    // is problematic because DCE may remove the AC instruction)
                    if (ac_results_src.isSet(dst_ptr)) break;
                    // Also check a broader set: is dst_ptr an AC result at all?
                    var dst_is_ac_result = false;
                    var pac: u32 = 5;
                    while (pac < words.len) {
                        const pac_h = words[pac]; const pac_wc: u32 = pac_h >> 16; const pac_op: u16 = @truncate(pac_h & 0xFFFF);
                        if (pac_wc == 0) break;
                        const pac_ie = pac + pac_wc;
                        if (pac_ie > words.len) break;
                        if (pac_op == 65 and pac_wc >= 3 and words[pac + 2] == dst_ptr) {
                            dst_is_ac_result = true;
                            break;
                        }
                        pac = pac_ie;
                    }
                    if (dst_is_ac_result) break;

                    try replacements.put(alloc, pos, .{ .load_pos = lpos, .src_ptr = src_ptr });
                    try dead_loads.put(alloc, lpos, {});
                    break;
                }
            }
            pos = ie2;
        }
    }

    if (replacements.count() == 0) return words;

    // Validate: build set of valid pointer IDs (defined by OpVariable or OpAccessChain)
    // CopyMemoryOpt can produce invalid IDs if earlier passes remapped or removed IDs
    var valid_ptr_ids = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer valid_ptr_ids.deinit();
    pos = 5;
    while (pos < words.len) {
        const wc3: u32 = words[pos] >> 16;
        const op3: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc3 == 0) break;
        const ie3 = pos + wc3;
        if (ie3 > words.len) break;
        if ((op3 == 59 or op3 == 65) and wc3 >= 4) { // OpVariable or OpAccessChain
            const rid3 = words[pos + 2];
            if (rid3 > 0 and rid3 < bound) valid_ptr_ids.set(rid3);
        }
        pos = ie3;
    }
    // Also add function parameters that are pointers (from OpFunctionParameter)
    pos = 5;
    while (pos < words.len) {
        const wc3: u32 = words[pos] >> 16;
        const op3: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc3 == 0) break;
        const ie3 = pos + wc3;
        if (ie3 > words.len) break;
        if (op3 == 55 and wc3 >= 3) { // OpFunctionParameter
            const rid3 = words[pos + 2];
            if (rid3 > 0 and rid3 < bound) valid_ptr_ids.set(rid3);
        }
        pos = ie3;
    }
    // Remove replacements where src_ptr or dst_ptr are not valid pointers
    var invalid_reps = std.ArrayList(u32).initCapacity(alloc, replacements.count()) catch return words;
    defer invalid_reps.deinit(alloc);
    var ri = replacements.iterator();
    while (ri.next()) |entry| {
        const sp = entry.value_ptr.src_ptr;
        const dp = words[entry.key_ptr.* + 1]; // dst_ptr from the OpStore
        const sp_valid = sp > 0 and sp < bound and valid_ptr_ids.isSet(sp);
        const dp_valid = dp > 0 and dp < bound and valid_ptr_ids.isSet(dp);
        if (!sp_valid or !dp_valid) {
            invalid_reps.appendAssumeCapacity(entry.key_ptr.*);
            // Also remove from dead_loads since we won't be removing this load
            _ = dead_loads.remove(entry.value_ptr.load_pos);
        }
    }
    for (invalid_reps.items) |store_pos| {
        _ = replacements.remove(store_pos);
    }
    if (replacements.count() == 0) return words;

    // Build set of PhysicalStorageBuffer pointer IDs to add Aligned operand
    var phys_sb_ids = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer phys_sb_ids.deinit();
    // Find OpVariable with PhysicalStorageBuffer (sc=5349)
    pos = 5;
    while (pos < words.len) {
        const wc2: u32 = words[pos] >> 16;
        const op2: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc2 == 0) break;
        const ie2 = pos + wc2;
        if (ie2 > words.len) break;
        if (op2 == 59 and wc2 >= 4) { // OpVariable
            const result = words[pos + 2];
            const sc = words[pos + 3];
            if (sc == 5349 and result > 0 and result < bound) phys_sb_ids.set(result);
        }
        pos = ie2;
    }
    // Find PhysSB pointer types (OpTypePointer with sc=5349)
    var phys_sb_ptr_types = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer phys_sb_ptr_types.deinit();
    pos = 5;
    while (pos < words.len) {
        const wc2: u32 = words[pos] >> 16;
        const op2: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc2 == 0) break;
        const ie2 = pos + wc2;
        if (ie2 > words.len) break;
        if (op2 == 32 and wc2 == 4) { // OpTypePointer
            const result = words[pos + 1];
            if (pos + 2 < ie2) {
                const sc = words[pos + 2];
                if (sc == 5349 and result > 0 and result < bound) phys_sb_ptr_types.set(result);
            }
        }
        pos = ie2;
    }
    // Propagate: OpLoad with PhysSB result type → result is PhysSB
    pos = 5;
    while (pos < words.len) {
        const wc2: u32 = words[pos] >> 16;
        const op2: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc2 == 0) break;
        const ie2 = pos + wc2;
        if (ie2 > words.len) break;
        if (op2 == 61 and wc2 >= 4) { // OpLoad
            const result_type_id = words[pos + 1];
            const result = words[pos + 2];
            if (result_type_id > 0 and result_type_id < bound and phys_sb_ptr_types.isSet(result_type_id) and result > 0 and result < bound) {
                phys_sb_ids.set(result);
            }
        }
        // AccessChain: propagate from base
        if (op2 == 65 and wc2 >= 4) { // OpAccessChain
            const base = words[pos + 3];
            const result = words[pos + 2];
            if (base > 0 and base < bound and phys_sb_ids.isSet(base) and result > 0 and result < bound) {
                phys_sb_ids.set(result);
            }
        }
        pos = ie2;
    }
    // Fixpoint propagation for AccessChain
    var fp_changed = true;
    while (fp_changed) {
        fp_changed = false;
        pos = 5;
        while (pos < words.len) {
            const wc2: u32 = words[pos] >> 16;
            const op2: u16 = @truncate(words[pos] & 0xFFFF);
            if (wc2 == 0) break;
            const ie2 = pos + wc2;
            if (ie2 > words.len) break;
            if (op2 == 65 and wc2 >= 4) { // OpAccessChain
                const base = words[pos + 3];
                const result = words[pos + 2];
                if (base > 0 and base < bound and phys_sb_ids.isSet(base) and result > 0 and result < bound and !phys_sb_ids.isSet(result)) {
                    phys_sb_ids.set(result);
                    fp_changed = true;
                }
            }
            if (op2 == 61 and wc2 >= 4) { // OpLoad
                const ptr = words[pos + 3];
                const result = words[pos + 2];
                if (ptr > 0 and ptr < bound and phys_sb_ids.isSet(ptr) and result > 0 and result < bound and !phys_sb_ids.isSet(result)) {
                    phys_sb_ids.set(result);
                    fp_changed = true;
                }
            }
            pos = ie2;
        }
    }

    // Phase 3: Rewrite - remove dead loads, replace stores with OpCopyMemory
    var result3 = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result3.appendSliceAssumeCapacity(words[0..5]);
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip dead loads
        if (dead_loads.contains(pos)) {
            pos = ie;
            continue;
        }

        // Replace stores that are in the replacement map with OpCopyMemory
        if (replacements.get(pos)) |rep| {
            const dst_ptr = words[pos + 1];
            const src_ptr = rep.src_ptr;
            const dst_is_phys = dst_ptr > 0 and dst_ptr < bound and phys_sb_ids.isSet(dst_ptr);
            const src_is_phys = src_ptr > 0 and src_ptr < bound and phys_sb_ids.isSet(src_ptr);
            if (dst_is_phys or src_is_phys) {
                // OpCopyMemory with Aligned for PhysSB
                result3.appendAssumeCapacity((5 << 16) | 63); // wc=5, opcode=63
                result3.appendAssumeCapacity(dst_ptr);
                result3.appendAssumeCapacity(src_ptr);
                result3.appendAssumeCapacity(2); // Aligned memory operand bit
                result3.appendAssumeCapacity(16); // alignment
            } else {
                // OpCopyMemory without memory operands
                result3.appendAssumeCapacity((3 << 16) | 63);
                result3.appendAssumeCapacity(dst_ptr);
                result3.appendAssumeCapacity(src_ptr);
            }
        } else {
            result3.appendSliceAssumeCapacity(words[pos..ie]);
        }
        pos = ie;
    }
    return result3.toOwnedSlice(alloc) catch return words;
}

/// Validate OpCopyMemory instructions: remove any whose source or target pointer
/// ID is not defined by an OpVariable, OpAccessChain, or OpFunctionParameter.
/// This is needed because earlier passes (scatterStoreToComposite) may eliminate
/// AccessChain instructions that copyMemoryOpt referenced.
pub fn validateCopyMemory(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Build set of defined pointer IDs
    var defined_ids = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer defined_ids.deinit();
    var pos: u32 = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        // Mark result IDs from Variable, AccessChain, FunctionParameter
        switch (opcode) {
            59 => { // OpVariable
                if (wc >= 3 and words[pos + 2] > 0 and words[pos + 2] < bound)
                    defined_ids.set(words[pos + 2]);
            },
            65 => { // OpAccessChain
                if (wc >= 3 and words[pos + 2] > 0 and words[pos + 2] < bound)
                    defined_ids.set(words[pos + 2]);
            },
            55 => { // OpFunctionParameter
                if (wc >= 3 and words[pos + 2] > 0 and words[pos + 2] < bound)
                    defined_ids.set(words[pos + 2]);
            },
            else => {},
        }
        // Also mark all result-producing instructions (for generic IDs)
        const info = compact_ids.getOpInfo(opcode) orelse {
            pos = ie;
            continue;
        };
        switch (info.fixed) {
            2 => { if (pos + 2 < ie) { const rid = words[pos + 2]; if (rid > 0 and rid < bound) defined_ids.set(rid); } },
            3 => { if (pos + 1 < ie) { const rid = words[pos + 1]; if (rid > 0 and rid < bound) defined_ids.set(rid); } },
            else => {},
        }
        pos = ie;
    }

    // Check for invalid CopyMemory instructions
    var any_invalid = false;
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 63 and wc >= 3) { // OpCopyMemory
            const dst = words[pos + 1];
            const src = words[pos + 2];
            if ((dst == 0 or dst >= bound or !defined_ids.isSet(dst)) or
                (src == 0 or src >= bound or !defined_ids.isSet(src))) {
                any_invalid = true;
                break;
            }
        }
        pos = ie;
    }

    if (!any_invalid) return words;

    // Rebuild: replace invalid CopyMemory with Load+Store
    var result = try std.ArrayList(u32).initCapacity(alloc, words.len);
    result.appendSliceAssumeCapacity(words[0..5]);
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 63 and wc >= 3) { // OpCopyMemory
            const dst = words[pos + 1];
            const src = words[pos + 2];
            const dst_ok = dst > 0 and dst < bound and defined_ids.isSet(dst);
            const src_ok = src > 0 and src < bound and defined_ids.isSet(src);
            if (!dst_ok or !src_ok) {
                // Skip this invalid CopyMemory instruction
                pos = ie;
                continue;
            }
        }
        result.appendSliceAssumeCapacity(words[pos..ie]);
        pos = ie;
    }
    return result.toOwnedSlice(alloc);
}

/// Remove identity stores: Load(P) -> Store(P, load_result) where load result is used only in the store.
/// This is a no-op store that can be safely removed along with the load.
pub fn elimIdentityStores(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find loads whose result is used exactly once, and that use is in an OpStore to the SAME pointer
    var load_positions = std.AutoHashMapUnmanaged(u32, u32).empty; // result_id -> pos
    defer load_positions.deinit(alloc);
    var use_count = std.AutoHashMapUnmanaged(u32, u32).empty; // result_id -> count
    defer use_count.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 61 and wc >= 4) { // OpLoad
            const rid = words[pos + 2];
            if (rid > 0 and rid < bound) {
                try load_positions.put(alloc, rid, pos);
                try use_count.put(alloc, rid, 0);
            }
        }
        pos = ie;
    }

    if (load_positions.count() == 0) return words;

    // Count uses of each load result (excluding the OpLoad instruction itself)
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode != 61) { // skip OpLoad
            const info = compact_ids.getOpInfo(opcode) orelse {
                var wi2: u32 = pos + 1;
                while (wi2 < ie) : (wi2 += 1) {
                    if (words[wi2] > 0 and words[wi2] < bound) {
                        if (use_count.getPtr(words[wi2])) |cnt| cnt.* += 1;
                    }
                }
                pos = ie;
                continue;
            };
            var wi: u32 = pos + 1;
            switch (info.fixed) {
                1 => { wi += 1; },
                2 => { wi += 2; },
                3 => { wi += 1; },
                else => {},
            }
            for (info.ops) |ch| {
                if (wi >= ie) break;
                switch (ch) {
                    'i' => {
                        if (words[wi] > 0 and words[wi] < bound) {
                            if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                        }
                        wi += 1;
                    },
                    'I' => { while (wi < ie) : (wi += 1) {
                        if (words[wi] > 0 and words[wi] < bound) {
                            if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                        }
                    }},
                    'l' => { wi += 1; },
                    'L' => { wi = ie; },
                    's' => { wi = ie; },
                    'M' => { if (wi < ie) { wi += 1; while (wi < ie) : (wi += 1) {
                        if (words[wi] > 0 and words[wi] < bound) {
                            if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                        }
                    }}},
                    'W' => { while (wi + 1 < ie) { wi += 1; if (words[wi] > 0 and words[wi] < bound) {
                        if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                    } wi += 1; } if (wi < ie) wi += 1; },
                    'E' => { while (wi < ie) { const ww = words[wi]; wi += 1; if ((ww & 0xFF) == 0 or ((ww >> 8) & 0xFF) == 0 or ((ww >> 16) & 0xFF) == 0 or ((ww >> 24) & 0xFF) == 0) break; } while (wi < ie) : (wi += 1) {
                        if (words[wi] > 0 and words[wi] < bound) {
                            if (use_count.getPtr(words[wi])) |cnt| cnt.* += 1;
                        }
                    }},
                    else => { wi += 1; },
                }
            }
        }
        pos = ie;
    }

    // Phase 2: Find identity stores (Load(P) -> Store(P, load_result)) with load used exactly once
    var remove_positions = std.AutoHashMapUnmanaged(u32, void).empty; // positions to skip
    defer remove_positions.deinit(alloc);

    var li = load_positions.iterator();
    while (li.next()) |entry| {
        const rid = entry.key_ptr.*;
        const lpos = entry.value_ptr.*;
        const cnt = use_count.get(rid) orelse 0;
        if (cnt != 1) continue;

        const src_ptr = words[lpos + 3]; // OpLoad: type, result, ptr

        // Find the OpStore that uses this value
        pos = 5;
        while (pos < words.len) {
            const wc2: u32 = words[pos] >> 16;
            const opcode2: u16 = @truncate(words[pos] & 0xFFFF);
            if (wc2 == 0) break;
            const ie2 = pos + wc2;
            if (ie2 > words.len) break;
            if (opcode2 == 62 and wc2 >= 3) { // OpStore
                const dst_ptr = words[pos + 1];
                const stored_val = words[pos + 2];
                if (stored_val == rid and dst_ptr == src_ptr) {
                    // Identity store found! Remove both load and store.
                    try remove_positions.put(alloc, lpos, {});
                    try remove_positions.put(alloc, pos, {});
                    break;
                }
            }
            pos = ie2;
        }
    }

    if (remove_positions.count() == 0) return words;
    std.log.debug("elimIdentityStores: {} removed", .{remove_positions.count()});

    // Phase 3: Rewrite
    var result4 = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result4.appendSliceAssumeCapacity(words[0..5]);
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (remove_positions.contains(pos)) {
            pos = ie;
            continue;
        }
        result4.appendSliceAssumeCapacity(words[pos..ie]);
        pos = ie;
    }
    return result4.toOwnedSlice(alloc) catch return words;
}


/// Eliminate dead functions: functions that are never called and are not entry points.
/// After elimDeadVoidCalls removes the calls, the function bodies become dead.
pub fn elimDeadFunctions(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Collect entry point function IDs
    var entry_funcs = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer entry_funcs.deinit();
    // Collect all function result IDs
    var func_ids = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer func_ids.deinit();
    // Count OpFunctionCall references per function
    var call_count = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer call_count.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 15 and wc >= 4) { // OpEntryPoint
            const func_id = words[pos + 2];
            if (func_id < bound) entry_funcs.set(func_id);
        }
        if (opcode == 54 and wc >= 3) { // OpFunction
            const result_id = words[pos + 2];
            if (result_id < bound) func_ids.set(result_id);
        }
        if (opcode == 57 and wc >= 4) { // OpFunctionCall
            const called_func = words[pos + 3];
            const entry = call_count.getOrPutValue(alloc, called_func, 0) catch null;
            if (entry) |e| e.value_ptr.* += 1;
        }
        pos = ie;
    }

    // Find dead functions (not called, not entry point)
    var dead_funcs = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer dead_funcs.deinit();
    {
        var fid: u32 = 0;
        while (fid < bound) : (fid += 1) {
            if (func_ids.isSet(fid) and !entry_funcs.isSet(fid)) {
                const calls = call_count.get(fid) orelse 0;
                if (calls == 0) {
                    dead_funcs.set(fid);
                }
            }
        }
    }

    if (dead_funcs.count() == 0) return words;

    // Collect IDs defined within dead functions (for DCE to clean up)
    // Build set of all IDs defined in dead function bodies
    var dead_ids = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer dead_ids.deinit();

    var in_dead_func = false;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 54 and wc >= 3) { // OpFunction
            const result_id = words[pos + 2];
            if (dead_funcs.isSet(result_id)) {
                in_dead_func = true;
                dead_ids.set(result_id);
            } else {
                in_dead_func = false;
            }
        } else if (opcode == 56) { // OpFunctionEnd
            if (in_dead_func) {
                // OpFunctionEnd has no result ID, just end tracking
            }
            in_dead_func = false;
        } else if (in_dead_func) {
            // Mark result IDs as dead
            const info = compact_ids.getOpInfo(opcode) orelse {
                pos = ie;
                continue;
            };
            switch (info.fixed) {
                1, 2 => {
                    if (wc >= 3 and words[pos + 2] < bound) {
                        dead_ids.set(words[pos + 2]);
                    }
                },
                3 => {
                    if (wc >= 2 and words[pos + 1] < bound) {
                        dead_ids.set(words[pos + 1]);
                    }
                },
                else => {},
            }
            // Also mark type-only results (TypeVoid, TypeInt, etc.)
            if (opcode >= 17 and opcode <= 39 and wc >= 2) {
                if (words[pos + 1] < bound) dead_ids.set(words[pos + 1]);
            }
        }
        pos = ie;
    }

    // Build new binary without dead functions and their references
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    in_dead_func = false;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 54 and wc >= 3) { // OpFunction
            const result_id = words[pos + 2];
            if (dead_funcs.isSet(result_id)) {
                in_dead_func = true;
                pos = ie;
                continue;
            }
            in_dead_func = false;
        } else if (opcode == 56 and in_dead_func) { // OpFunctionEnd
            in_dead_func = false;
            pos = ie;
            continue;
        }

        if (in_dead_func) {
            pos = ie;
            continue;
        }

        // Skip OpName/OpDecorate targeting dead function IDs
        if (opcode == 5 and wc >= 2 and dead_funcs.isSet(words[pos + 1])) { // OpName
            pos = ie;
            continue;
        }
        if (opcode == 71 and wc >= 3 and dead_funcs.isSet(words[pos + 1])) { // OpDecorate
            pos = ie;
            continue;
        }
        if (opcode == 72 and wc >= 4 and dead_funcs.isSet(words[pos + 1])) { // OpMemberDecorate
            pos = ie;
            continue;
        }

        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }

    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}

/// Hoist invariant AccessChain instructions from branch targets to the header block.
/// When an OpSelectionMerge + OpBranchConditional creates sibling blocks,
/// and two or more targets contain ACs with identical (result_type, base, indices),
/// hoist one AC to the header block (before OpSelectionMerge) and replace
/// all duplicates with the hoisted result. Saves (N-1) IDs per pattern.
pub fn hoistInvariantACs(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Find all OpSelectionMerge + OpBranchConditional pairs
    // and check if their targets have matching ACs
    const HoistTarget = struct {
        merge_pos: u32,      // position of OpSelectionMerge
        branch_pos: u32,     // position of OpBranchConditional
        header_end: u32,     // end of header block (position of SelectionMerge)
        ac_result: u32,      // result ID of the hoisted AC (reuse one from a target)
        ac_result_type: u32, // result type
        ac_base: u32,        // base operand
        ac_indices_start: u32, // start index in indices_buf
        ac_indices_len: u32,   // number of indices
        dup_results: []u32,    // AC result IDs to replace with ac_result
    };

    var targets = std.ArrayListUnmanaged(HoistTarget).empty;
    defer targets.deinit(alloc);
    var indices_buf = std.ArrayListUnmanaged(u32).empty;
    defer indices_buf.deinit(alloc);
    var dup_buf = std.ArrayListUnmanaged(u32).empty;
    defer dup_buf.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Look for OpSelectionMerge (opcode 247)
        if (opcode == 247 and wc >= 3) {
            // Next instruction should be OpBranchConditional (opcode 250)
            const next_pos = ie;
            if (next_pos < words.len) {
                const next_hdr = words[next_pos];
                const next_wc: u32 = next_hdr >> 16;
                const next_op: u16 = @truncate(next_hdr & 0xFFFF);
                const next_ie = next_pos + next_wc;
                if (next_op == 250 and next_wc >= 4 and next_ie <= words.len) {
                    // OpBranchConditional: cond, true_label, false_label [,weights]
                    const true_label = words[next_pos + 2];
                    const false_label = words[next_pos + 3];

                    // Find ACs in the true and false blocks
                    // True block starts at the OpLabel with true_label
                    // False block starts at the OpLabel with false_label
                    const TrueFalseACs = struct { result: u32, result_type: u32, base: u32, idx_start: u32, idx_len: u32 };
                    var true_acs = std.ArrayListUnmanaged(TrueFalseACs).empty;
                    defer true_acs.deinit(alloc);
                    var false_acs = std.ArrayListUnmanaged(TrueFalseACs).empty;
                    defer false_acs.deinit(alloc);

                    // Scan for blocks after the branch
                    var bp: u32 = next_ie;
                    while (bp < words.len) {
                        const bh = words[bp];
                        const bwc: u32 = bh >> 16;
                        const bop: u16 = @truncate(bh & 0xFFFF);
                        if (bwc == 0) break;
                        const bie = bp + bwc;
                        if (bie > words.len) break;
                        if (bop == 56) break; // OpFunctionEnd

                        if (bop == 248 and bwc >= 2) { // OpLabel
                            const block_id = words[bp + 1];
                            const is_true = (block_id == true_label);
                            const is_false = (block_id == false_label);
                            if (is_true or is_false) {
                                // Scan instructions in this block until next OpLabel or OpFunctionEnd
                                var ip: u32 = bie;
                                while (ip < words.len) {
                                    const ih = words[ip];
                                    const iwc: u32 = ih >> 16;
                                    const iop: u16 = @truncate(ih & 0xFFFF);
                                    if (iwc == 0) break;
                                    const iie = ip + iwc;
                                    if (iie > words.len) break;
                                    if (iop == 248 or iop == 56) break; // next block or function end
                                    if (iop == 65 and iwc >= 5) { // OpAccessChain
                                        const ac = TrueFalseACs{
                                            .result = words[ip + 2],
                                            .result_type = words[ip + 1],
                                            .base = words[ip + 3],
                                            .idx_start = @intCast(indices_buf.items.len),
                                            .idx_len = @intCast(iwc - 4),
                                        };
                                        var j: u32 = 4;
                                        while (j < iwc) : (j += 1) {
                                            indices_buf.append(alloc, words[ip + j]) catch return words;
                                        }
                                        if (is_true) {
                                            true_acs.append(alloc, ac) catch return words;
                                        } else {
                                            false_acs.append(alloc, ac) catch return words;
                                        }
                                    }
                                    ip = iie;
                                }
                            }
                        }
                        bp = bie;
                    }

                    // Find matching ACs between true and false blocks
                    for (true_acs.items, 0..) |tac, ti| {
                        for (false_acs.items, 0..) |fac, fi| {
                            if (tac.result_type == fac.result_type and tac.base == fac.base and tac.idx_len == fac.idx_len) {
                                const t_indices = indices_buf.items[tac.idx_start..tac.idx_start + tac.idx_len];
                                const f_indices = indices_buf.items[fac.idx_start..fac.idx_start + fac.idx_len];
                                if (std.mem.eql(u32, t_indices, f_indices)) {
                                    // Match found! Hoist to header block.
                                    // Reuse the true branch's AC result.
                                    const dups_start = dup_buf.items.len;
                                    dup_buf.append(alloc, fac.result) catch return words;

                                    targets.append(alloc, .{
                                        .merge_pos = pos,
                                        .branch_pos = next_pos,
                                        .header_end = pos, // insert AC just before OpSelectionMerge
                                        .ac_result = tac.result,
                                        .ac_result_type = tac.result_type,
                                        .ac_base = tac.base,
                                        .ac_indices_start = tac.idx_start,
                                        .ac_indices_len = tac.idx_len,
                                        .dup_results = dup_buf.items[dups_start .. dup_buf.items.len],
                                    }) catch return words;

                                    // Mark these as used so we don't match them again
                                    _ = ti;
                                    _ = fi;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
        pos = ie;
    }

    if (targets.items.len == 0) return words;

    // Build substitution map
    var sub_map = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer sub_map.deinit(alloc);
    // Set of positions to skip (duplicate AC definitions)
    var skip_set = std.AutoHashMapUnmanaged(u32, void).empty;
    defer skip_set.deinit(alloc);

    for (targets.items) |t| {
        for (t.dup_results) |dup_id| {
            try sub_map.put(alloc, dup_id, t.ac_result);
        }
    }

    // Now we need to:
    // 1. Find the duplicate AC instructions (by their result IDs) and skip them
    // 2. Apply substitution to all uses of dup_result → ac_result
    // 3. Don't insert into the header — the AC from the true branch stays in the true block
    //    but its result is now also used in the false block (via substitution)

    // Wait, this approach is wrong. If the AC is in the true block, its result can't be
    // used in the false block (sibling blocks don't dominate each other).
    // We need to actually MOVE the AC to the header block (before OpSelectionMerge).

    // Better approach: insert the AC just before OpSelectionMerge in the header block,
    // remove all duplicate ACs, and substitute all uses.

    // Find positions of ACs to skip: both hoisted originals and duplicates
    var hoisted_results = std.AutoHashMapUnmanaged(u32, void).empty;
    defer hoisted_results.deinit(alloc);
    for (targets.items) |t| {
        try hoisted_results.put(alloc, t.ac_result, {});
    }
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 65 and wc >= 5) { // OpAccessChain
            const result_id = words[pos + 2];
            if (sub_map.contains(result_id) or hoisted_results.contains(result_id)) {
                try skip_set.put(alloc, pos, {});
            }
        }
        pos = ie;
    }

    // Build output: insert hoisted ACs before each OpSelectionMerge, skip dups
    var result = std.ArrayList(u32).initCapacity(alloc, words.len + targets.items.len * 10) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Check if we need to insert a hoisted AC before this position
        for (targets.items) |t| {
            if (pos == t.merge_pos) {
                // Insert the hoisted AC just before OpSelectionMerge
                const indices = indices_buf.items[t.ac_indices_start..t.ac_indices_start + t.ac_indices_len];
                const ac_wc: u16 = @intCast(4 + t.ac_indices_len);
                result.append(alloc, (@as(u32, ac_wc) << 16) | 65) catch return words;
                result.append(alloc, t.ac_result_type) catch return words;
                result.append(alloc, t.ac_result) catch return words;
                result.append(alloc, t.ac_base) catch return words;
                for (indices) |idx| {
                    result.append(alloc, idx) catch return words;
                }
            }
        }

        // Skip duplicate ACs
        if (skip_set.contains(pos)) {
            pos = ie;
            continue;
        }

        // Apply substitution using getOpInfo
        const info = compact_ids.getOpInfo(opcode) orelse {
            var wi: u32 = 0;
            while (wi < wc) : (wi += 1) {
                const w = words[pos + wi];
                result.append(alloc, sub_map.get(w) orelse w) catch return words;
            }
            pos = ie;
            continue;
        };

        result.append(alloc, hdr) catch return words;
        var wi: u32 = pos + 1;
        switch (info.fixed) {
            0 => {},
            1 => {
                if (wi < ie) { const w = words[wi]; result.append(alloc, sub_map.get(w) orelse w) catch return words; wi += 1; }
            },
            2 => {
                if (wi < ie) { const w = words[wi]; result.append(alloc, sub_map.get(w) orelse w) catch return words; wi += 1; }
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } // result ID, don't sub
            },
            3 => {
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } // result ID, don't sub
            },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { const w = words[wi]; result.append(alloc, sub_map.get(w) orelse w) catch return words; wi += 1; },
                'l' => { result.append(alloc, words[wi]) catch return words; wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) { const w = words[wi]; result.append(alloc, sub_map.get(w) orelse w) catch return words; } },
                'L', 's' => { while (wi < ie) : (wi += 1) { result.append(alloc, words[wi]) catch return words; } },
                'M' => {
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                    while (wi < ie) : (wi += 1) { const w = words[wi]; result.append(alloc, sub_map.get(w) orelse w) catch return words; }
                },
                'W' => {
                    while (wi + 1 < ie) {
                        result.append(alloc, words[wi]) catch return words; // literal
                        wi += 1;
                        const w = words[wi]; result.append(alloc, sub_map.get(w) orelse w) catch return words; // target
                        wi += 1;
                    }
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                },
                'E' => {
                    var in_str = true;
                    while (wi < ie and in_str) : (wi += 1) {
                        const w = words[wi]; result.append(alloc, w) catch return words;
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) in_str = false;
                    }
                    while (wi < ie) : (wi += 1) { const w = words[wi]; result.append(alloc, sub_map.get(w) orelse w) catch return words; }
                },
                else => { result.append(alloc, words[wi]) catch return words; wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words;
        pos = ie;
    }

    const nw = result.toOwnedSlice(alloc) catch return words;
    return nw;
}

/// Convert branch-merge variables to OpPhi.
/// When a variable is stored in all predecessor blocks of a merge block and
/// loaded in the merge block, replace with OpPhi to eliminate the variable, stores, and load.
pub fn branchMergePhi(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // ---- Phase 1: Build CFG ----
    const BlockInfo = struct {
        preds: std.ArrayListUnmanaged(u32),
        succs: std.ArrayListUnmanaged(u32),
        stores: std.AutoHashMapUnmanaged(u32, u32),
        loads: std.AutoHashMapUnmanaged(u32, u32),
    };
    var block_map = std.AutoHashMapUnmanaged(u32, BlockInfo).empty;
    defer {
        var it = block_map.iterator();
        while (it.next()) |e| {
            e.value_ptr.preds.deinit(alloc);
            e.value_ptr.succs.deinit(alloc);
            e.value_ptr.stores.deinit(alloc);
            e.value_ptr.loads.deinit(alloc);
        }
        block_map.deinit(alloc);
    }

    var cur_block: u32 = 0;
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (op == 248) {
            cur_block = words[pos + 1];
            const gop = try block_map.getOrPut(alloc, cur_block);
            if (!gop.found_existing) gop.value_ptr.* = .{ .preds = .empty, .succs = .empty, .stores = .empty, .loads = .empty };
        }
        if (block_map.getPtr(cur_block)) |b| {
            if (op == 62 and wc >= 3) try b.stores.put(alloc, words[pos + 1], words[pos + 2]);
            if (op == 61 and wc >= 4) try b.loads.put(alloc, words[pos + 3], words[pos + 2]);
            if (op == 249 and wc >= 2) try b.succs.append(alloc, words[pos + 1]);
            if (op == 250 and wc >= 4) { try b.succs.append(alloc, words[pos + 2]); try b.succs.append(alloc, words[pos + 3]); }
            if (op == 251 and wc >= 3) { try b.succs.append(alloc, words[pos + 2]); var i: u32 = 4; while (i < wc) : (i += 2) try b.succs.append(alloc, words[pos + i]); }
        }
        pos = ie;
    }
    { var it = block_map.iterator(); while (it.next()) |e| { for (e.value_ptr.succs.items) |s| { if (block_map.getPtr(s)) |sb| try sb.preds.append(alloc, e.key_ptr.*); } } }

    // ---- Phase 2: Find candidates ----
    // Look for merge blocks (2+ preds) where a variable is stored in ALL predecessors.
    // The variable must be loaded somewhere (not necessarily in the merge block).
    // No other block may store the variable.
    const Cand = struct { merge_block: u32, var_id: u32, first_load_result: u32, result_type: u32, pred_count: u32, all_load_results: std.ArrayListUnmanaged(u32) };
    var cands = std.ArrayListUnmanaged(Cand).empty;
    defer {
        for (cands.items) |*c| c.all_load_results.deinit(alloc);
        cands.deinit(alloc);
    }
    {
        // Collect all function-scope variable IDs
        var func_var_ids = std.AutoHashMapUnmanaged(u32, void).empty;
        defer func_var_ids.deinit(alloc);
        pos = 5;
        while (pos < words.len) {
            const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
            if (wc == 0) break; const ie = pos + wc; if (ie > words.len) break;
            if (op == 59 and wc >= 4 and words[pos + 3] == 7) { // OpVariable Function
                try func_var_ids.put(alloc, words[pos + 2], {});
            }
            pos = ie;
        }

        var bit = block_map.iterator();
        while (bit.next()) |entry| {
            const bid = entry.key_ptr.*; const block = entry.value_ptr.*;
            if (block.preds.items.len < 2) continue;

            // For each predecessor, get the set of stored variables
            var pred_stored = std.AutoHashMapUnmanaged(u32, void).empty;
            defer pred_stored.deinit(alloc);
            var first = true;
            for (block.preds.items) |pred| {
                if (block_map.get(pred)) |pb| {
                    if (first) {
                        var si = pb.stores.iterator();
                        while (si.next()) |se| {
                            if (func_var_ids.contains(se.key_ptr.*))
                                try pred_stored.put(alloc, se.key_ptr.*, {});
                        }
                        first = false;
                    } else {
                        // Remove variables not stored in this pred
                        var to_remove = std.ArrayListUnmanaged(u32).empty;
                        defer to_remove.deinit(alloc);
                        var psi = pred_stored.iterator();
                        while (psi.next()) |pe| {
                            if (!pb.stores.contains(pe.key_ptr.*)) try to_remove.append(alloc, pe.key_ptr.*);
                        }
                        for (to_remove.items) |rid| _ = pred_stored.remove(rid);
                    }
                }
            }

            // For each variable stored in ALL predecessors
            var psi2 = pred_stored.iterator();
            while (psi2.next()) |pe| {
                const var_id = pe.key_ptr.*;

                // Safety: no non-predecessor block may STORE this variable
                var bad = false;
                var cit = block_map.iterator();
                while (cit.next()) |ce| {
                    if (ce.key_ptr.* == bid) continue;
                    var is_pred = false;
                    for (block.preds.items) |p| { if (ce.key_ptr.* == p) { is_pred = true; break; } }
                    if (is_pred) continue;
                    if (ce.value_ptr.stores.contains(var_id)) { bad = true; break; }
                }
                if (bad) continue;

                // Safety: skip variables that have OpAccessChain instructions
                // pointing into them — removing the variable would leave
                // dangling AccessChain references
                var has_ac = false;
                var acp: u32 = 5;
                while (acp < words.len) {
                    const ach = words[acp]; const acwc: u32 = ach >> 16; const acop: u16 = @truncate(ach & 0xFFFF);
                    if (acwc == 0) break; const acie = acp + acwc; if (acie > words.len) break;
                    if (acop == 65 and acwc >= 5 and words[acp + 3] == var_id) { has_ac = true; break; }
                    acp = acie;
                }
                if (has_ac) continue;

                // Find ALL loads of this variable across all blocks
                var all_loads = std.ArrayListUnmanaged(u32).empty;
                var rtype: u32 = 0;
                var ait = block_map.iterator();
                while (ait.next()) |ae| {
                    var ale = ae.value_ptr.loads.iterator();
                    while (ale.next()) |al| {
                        if (al.key_ptr.* == var_id) {
                            try all_loads.append(alloc, al.value_ptr.*);
                            // Get result type from the first load
                            if (rtype == 0) {
                                var p2: u32 = 5;
                                while (p2 < words.len) {
                                    const h = words[p2]; const ww: u32 = h >> 16; const o: u16 = @truncate(h & 0xFFFF);
                                    if (ww == 0) break; const e = p2 + ww; if (e > words.len) break;
                                    if (o == 61 and ww >= 4 and words[p2 + 2] == al.value_ptr.*) { rtype = words[p2 + 1]; break; }
                                    p2 = e;
                                }
                            }
                        }
                    }
                }
                if (all_loads.items.len == 0 or rtype == 0) { all_loads.deinit(alloc); continue; }

                const first_load = all_loads.items[0];
                try cands.append(alloc, .{ .merge_block = bid, .var_id = var_id, .first_load_result = first_load, .result_type = rtype, .pred_count = @as(u32, @intCast(block.preds.items.len)), .all_load_results = all_loads });
            }
        }
    }
    if (cands.items.len == 0) return words;

    // ---- Phase 3: Build maps ----
    var load_map = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer load_map.deinit(alloc);
    var pred_load_map = std.AutoHashMapUnmanaged(u32, u32).empty; // load results in pred blocks -> dominator store value
    defer pred_load_map.deinit(alloc);
    var remove_vars = std.AutoHashMapUnmanaged(u32, void).empty;
    defer remove_vars.deinit(alloc);
    var remove_stores = std.AutoHashMapUnmanaged(u64, void).empty;
    defer remove_stores.deinit(alloc);
    const PhiBlockList = std.ArrayListUnmanaged(u32);
    var phi_blocks = std.AutoHashMapUnmanaged(u32, PhiBlockList).empty; // merge_block -> list of candidate indices
    defer {
        var pbit = phi_blocks.iterator();
        while (pbit.next()) |e| e.value_ptr.deinit(alloc);
        phi_blocks.deinit(alloc);
    }
    var next_id: u32 = bound;
    for (cands.items, 0..) |c, ci| {
        try load_map.put(alloc, c.first_load_result, next_id);
        try remove_vars.put(alloc, c.var_id, {});
        // Map ALL loads (including those outside the merge block)
        for (c.all_load_results.items) |lr| {
            try load_map.put(alloc, lr, next_id);
        }
        // For loads in predecessor blocks that also load the variable,
        // map them to the dominator store value (the value before the branch).
        // This avoids circular phi references where OpFAdd uses the phi result.
        const mb_preds = block_map.get(c.merge_block).?.preds.items;
        // Find the dominator store value: the store from a pred that doesn't also load the variable
        var dominator_store_val: ?u32 = null;
        for (mb_preds) |pred| {
            if (block_map.get(pred)) |pb| {
                if (pb.stores.contains(c.var_id) and !pb.loads.contains(c.var_id)) {
                    dominator_store_val = pb.stores.get(c.var_id).?;
                    break;
                }
            }
        }
        if (dominator_store_val == null) {
            for (mb_preds) |pred| {
                if (block_map.get(pred)) |pb| {
                    if (pb.stores.get(c.var_id)) |val| { dominator_store_val = val; break; }
                }
            }
        }
        if (dominator_store_val) |dval| {
            for (mb_preds) |pred| {
                if (block_map.get(pred)) |pb| {
                    if (pb.loads.contains(c.var_id)) {
                        var lri = pb.loads.iterator();
                        while (lri.next()) |lr| {
                            if (lr.key_ptr.* == c.var_id) {
                                try pred_load_map.put(alloc, lr.value_ptr.*, dval);
                            }
                        }
                    }
                }
            }
        }
        var bit2 = block_map.iterator();
        while (bit2.next()) |e| {
            if (e.value_ptr.stores.contains(c.var_id)) {
                try remove_stores.put(alloc, (@as(u64, e.key_ptr.*) << 32) | @as(u64, c.var_id), {});
            }
        }
        const gop = try phi_blocks.getOrPut(alloc, c.merge_block);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(alloc, @as(u32, @intCast(ci)));
        next_id += 1;
    }

    // ---- Phase 4: Emit output using fixed buffer ----
    // First pass: count output words
    var out_words: u32 = 5; // header
    cur_block = 0;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break; const ie = pos + wc; if (ie > words.len) break;
        if (op == 248) cur_block = words[pos + 1];
        if (op == 59 and wc >= 4 and remove_vars.contains(words[pos + 2])) { pos = ie; continue; }
        if (op == 61 and wc >= 4 and load_map.contains(words[pos + 2])) { pos = ie; continue; }
        if (op == 62 and wc >= 3) {
            if (remove_stores.contains((@as(u64, cur_block) << 32) | @as(u64, words[pos + 1]))) { pos = ie; continue; }
        }
        out_words += wc;
        if (op == 248) {
            if (phi_blocks.get(cur_block)) |ci_list| {
                for (ci_list.items) |ci| {
                    out_words += 3 + 2 * cands.items[ci].pred_count; // OpPhi
                }
            }
        }
        pos = ie;
    }

    // Allocate output buffer
    var out = try alloc.alloc(u32, out_words);
    var opos: u32 = 0;
    // Copy header
    @memcpy(out[0..5], words[0..5]);
    out[3] = next_id;
    opos = 5;

    // Second pass: fill output
    cur_block = 0;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break; const ie = pos + wc; if (ie > words.len) break;
        if (op == 248) cur_block = words[pos + 1];
        if (op == 59 and wc >= 4 and remove_vars.contains(words[pos + 2])) { pos = ie; continue; }
        if (op == 61 and wc >= 4 and load_map.contains(words[pos + 2])) { pos = ie; continue; }
        if (op == 62 and wc >= 3) {
            if (remove_stores.contains((@as(u64, cur_block) << 32) | @as(u64, words[pos + 1]))) { pos = ie; continue; }
        }
        // Copy instruction
        @memcpy(out[opos..opos + wc], words[pos..ie]);
        opos += wc;
        // Insert OpPhi after OpLabel for merge blocks
        if (op == 248) {
            if (phi_blocks.get(cur_block)) |ci_list| {
                for (ci_list.items) |ci| {
                    const c = cands.items[ci];
                    const phi_wc: u32 = 3 + 2 * c.pred_count;
                    out[opos] = (phi_wc << 16) | 245; // OpPhi = 245
                    out[opos + 1] = c.result_type;
                    out[opos + 2] = load_map.get(c.first_load_result).?;
                    var pi: u32 = 0;
                    for (block_map.get(c.merge_block).?.preds.items) |pred| {
                        const val = block_map.get(pred).?.stores.get(c.var_id).?;
                        out[opos + 3 + pi * 2] = val;
                        out[opos + 3 + pi * 2 + 1] = pred;
                        pi += 1;
                    }
                    opos += phi_wc;
                }
            }
        }
        pos = ie;
    }

    // ---- Phase 5: ID substitution ----
    // Use pred_load_map as override for loads in predecessor blocks (to avoid circular phi refs)
    var spos: u32 = 5;
    while (spos < out.len) {
        const shdr = out[spos]; const swc: u32 = shdr >> 16; const sop: u16 = @truncate(shdr & 0xFFFF);
        if (swc == 0) break; const sie = spos + swc; if (sie > out.len) break;
        const info = compact_ids.getOpInfo(sop) orelse { spos = sie; continue; };
        var wi: u32 = spos + 1;
        switch (info.fixed) {
            1 => { if (wi < sie) wi += 1; },
            2 => { if (wi + 1 < sie) wi += 2; },
            3 => { if (wi < sie) wi += 1; },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= sie) break;
            switch (ch) {
                'i' => {
                    if (pred_load_map.get(out[wi])) |v| { out[wi] = v; }
                    else if (load_map.get(out[wi])) |v| { out[wi] = v; }
                    wi += 1;
                },
                'l' => { wi += 1; },
                'I' => { while (wi < sie) : (wi += 1) {
                    if (pred_load_map.get(out[wi])) |v| { out[wi] = v; }
                    else if (load_map.get(out[wi])) |v| { out[wi] = v; }
                } },
                'L', 's' => { while (wi < sie) : (wi += 1) {} },
                'M' => { if (wi < sie) wi += 1; while (wi < sie) : (wi += 1) {
                    if (pred_load_map.get(out[wi])) |v| { out[wi] = v; }
                    else if (load_map.get(out[wi])) |v| { out[wi] = v; }
                } },
                'W' => { while (wi + 1 < sie) { wi += 1; // skip literal, now at target
                    if (pred_load_map.get(out[wi])) |v| { out[wi] = v; }
                    else if (load_map.get(out[wi])) |v| { out[wi] = v; }
                    wi += 1; // advance past target
                } },
                else => { wi += 1; },
            }
        }
        spos = sie;
    }

    // Trim to actual size (counting pass may overcount)
    return out[0..opos];
}

/// Remove unused OpExtInstImport instructions.
/// OpExtInstImport declares an external instruction set (e.g., GLSLstd450).
/// If no OpExtInst references it, the import is unused and can be removed.
pub fn elimUnusedImports(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Find all OpExtInstImport (opcode 11) result IDs
    var imports = std.AutoHashMapUnmanaged(u32, void).empty;
    defer imports.deinit(alloc);
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (op == 11 and wc >= 2) {
            try imports.put(alloc, words[pos + 1], {});
        }
        pos = ie;
    }
    if (imports.count() == 0) return words;

    // Mark imports that are referenced by OpExtInst (opcode 12)
    // OpExtInst format: header | result_type | result_id | import_id | instruction | operands...
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (op == 12 and wc >= 4) {
            _ = imports.remove(words[pos + 3]); // import_id (set) is at word 3 after header
        }
        pos = ie;
    }
    if (imports.count() == 0) return words; // all imports are used

    // Remove unused imports
    var result = try std.ArrayList(u32).initCapacity(alloc, words.len);
    errdefer result.deinit(alloc);
    result.appendSliceAssumeCapacity(words[0..5]);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (op == 11 and wc >= 2 and imports.contains(words[pos + 1])) {
            pos = ie; // skip unused import
            continue;
        }
        result.appendSliceAssumeCapacity(words[pos..ie]);
        pos = ie;
    }
    return result.toOwnedSlice(alloc) catch return words;
}

/// Eliminate unused global variables (OpVariable in global scope that are never
/// used as pointer operands in OpLoad, OpStore, OpAccessChain, OpCopyMemory, etc.)
/// Removes the variable from OpEntryPoint, its decorations, names, and the variable itself.
/// Subsequent DCE will cascade to remove dead types.

/// Eliminate unused global variables (OpVariable in global scope that are never
/// used as pointer operands in OpLoad, OpStore, OpAccessChain, OpCopyMemory, etc.)
/// Removes the variable from OpEntryPoint, its decorations, names, and the variable itself.
/// Subsequent DCE will cascade to remove dead types.
pub fn elimUnusedGlobals(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find global OpVariable IDs (outside functions)
    var global_vars = std.AutoHashMapUnmanaged(u32, void).empty;
    defer global_vars.deinit(alloc);
    // Track which globals are output variables (storage class 3 = Output)
    // These should never be removed as they're used by the fixed-function pipeline
    var output_vars = std.AutoHashMapUnmanaged(u32, void).empty;
    defer output_vars.deinit(alloc);
    var in_func = false;
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (op == 54) in_func = true;
        if (op == 56) in_func = false;
        if (op == 59 and !in_func and wc >= 4) {
            try global_vars.put(alloc, words[pos + 2], {});
            // Storage class is at pos+3. 3 = Output
            if (words[pos + 3] == 3) {
                try output_vars.put(alloc, words[pos + 2], {});
            }
        }
        pos = ie;
    }
    if (global_vars.count() == 0) return words;

    // Phase 1.5: Find orphaned interface IDs (referenced in OpEntryPoint but no definition)
    // These can occur when DCE removes a variable before elimUnusedGlobals runs
    var defined_ids = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer defined_ids.deinit();
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        // Mark result IDs as defined
        const info = compact_ids.getOpInfo(op) orelse {
            pos = ie;
            continue;
        };
        switch (info.fixed) {
            1 => { if (wc >= 2) { const rid = words[pos + 1]; if (rid < bound) defined_ids.set(rid); } },
            2 => { if (wc >= 3) { const rid = words[pos + 2]; if (rid < bound) defined_ids.set(rid); } },
            3 => { if (wc >= 2) { const rid = words[pos + 1]; if (rid < bound) defined_ids.set(rid); } },
            else => {},
        }
        // Also mark OpVariable result IDs
        if (op == 59 and wc >= 3) {
            const rid = words[pos + 2];
            if (rid < bound) defined_ids.set(rid);
        }
        pos = ie;
    }
    // Find OpEntryPoint interface IDs that have no definition
    var orphaned = std.AutoHashMapUnmanaged(u32, void).empty;
    defer orphaned.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (op == 15 and wc >= 4) { // OpEntryPoint
            var str_end: u32 = pos + 3;
            while (str_end < ie) : (str_end += 1) {
                const sw = words[str_end];
                if ((sw & 0xFF) == 0 or ((sw >> 8) & 0xFF) == 0 or ((sw >> 16) & 0xFF) == 0 or ((sw >> 24) & 0xFF) == 0) {
                    str_end += 1;
                    break;
                }
            }
            var ip: u32 = str_end;
            while (ip < ie) : (ip += 1) {
                const iid = words[ip];
                if (iid >= 1 and iid < bound and !defined_ids.isSet(iid)) {
                    try orphaned.put(alloc, iid, {});
                    try global_vars.put(alloc, iid, {}); // treat as global for removal
                }
            }
        }
        pos = ie;
    }

    // Phase 2: Count real uses — only count actual ID operand positions using getOpInfo
    var use_count = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer use_count.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        // Skip: OpEntryPoint(15), OpName(5), OpMemberName(6), OpDecorate(71), OpMemberDecorate(72)
        // Also skip OpVariable itself (59) — that's the definition
        if (op != 15 and op != 5 and op != 6 and op != 71 and op != 72 and op != 59) {
            const info = compact_ids.getOpInfo(op);
            if (info) |inf| {
                // Use getOpInfo to identify which words are ID operands
                var wi: u32 = pos + 1;
                switch (inf.fixed) {
                    0 => {},
                    1 => { if (wi < ie) wi += 1; }, // type only, skip
                    2 => { if (wi < ie) wi += 1; if (wi < ie) wi += 1; }, // type + result, skip
                    3 => { if (wi < ie) { // result_only: word[1] is result
                        const rid = words[wi];
                        if (global_vars.contains(rid)) {
                            const g = try use_count.getOrPut(alloc, rid);
                            if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                        }
                        wi += 1;
                    }},
                    else => {},
                }
                // Process operand types
                for (inf.ops) |ch| {
                    if (wi >= ie) break;
                    switch (ch) {
                        'i' => { // ID operand
                            const word = words[wi];
                            if (global_vars.contains(word)) {
                                const g = try use_count.getOrPut(alloc, word);
                                if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                            }
                            wi += 1;
                        },
                        'l' => { wi += 1; }, // single literal
                        'L', 's' => { wi = ie; }, // consume rest as literals
                        'I' => { // ID variadic
                            while (wi < ie) : (wi += 1) {
                                const word = words[wi];
                                if (global_vars.contains(word)) {
                                    const g = try use_count.getOrPut(alloc, word);
                                    if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                                }
                            }
                        },
                        'M' => { // mixed: literal then IDs
                            if (wi < ie) wi += 1; // skip literal
                            while (wi < ie) : (wi += 1) {
                                const word = words[wi];
                                if (global_vars.contains(word)) {
                                    const g = try use_count.getOrPut(alloc, word);
                                    if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                                }
                            }
                        },
                        'W' => { // literal-ID pairs
                            while (wi + 1 < ie) {
                                wi += 1; // skip literal
                                const word = words[wi];
                                if (global_vars.contains(word)) {
                                    const g = try use_count.getOrPut(alloc, word);
                                    if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                                }
                                wi += 1;
                            }
                            if (wi < ie) wi += 1;
                        },
                        'E' => { // string then IDs
                            var in_str = true;
                            while (wi < ie and in_str) : (wi += 1) {
                                const sw = words[wi];
                                if ((sw & 0xFF) == 0 or ((sw >> 8) & 0xFF) == 0 or
                                    ((sw >> 16) & 0xFF) == 0 or ((sw >> 24) & 0xFF) == 0) {
                                    in_str = false;
                                }
                            }
                            while (wi < ie) : (wi += 1) {
                                const word = words[wi];
                                if (global_vars.contains(word)) {
                                    const g = try use_count.getOrPut(alloc, word);
                                    if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                                }
                            }
                        },
                        else => { wi += 1; },
                    }
                }
                // Handle any remaining words (shouldn't happen but be safe)
                while (wi < ie) : (wi += 1) {
                    const word = words[wi];
                    if (global_vars.contains(word)) {
                        const g = try use_count.getOrPut(alloc, word);
                        if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                    }
                }
            } else {
                // No opInfo — count all words conservatively
                for (1..wc) |i| {
                    const word = words[pos + i];
                    if (global_vars.contains(word)) {
                        const g = try use_count.getOrPut(alloc, word);
                        if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                    }
                }
            }
        }
        pos = ie;
    }

    // Build unused set (but never remove output variables)
    var unused = std.AutoHashMapUnmanaged(u32, void).empty;
    defer unused.deinit(alloc);
    var it = global_vars.iterator();
    while (it.next()) |entry| {
        const vid = entry.key_ptr.*;
        if ((use_count.get(vid) orelse 0) == 0 and !output_vars.contains(vid)) {
            try unused.put(alloc, vid, {});
        }
    }
    if (unused.count() == 0) return words;

    // Phase 3: Rewrite
    var result = try std.ArrayList(u32).initCapacity(alloc, words.len);
    errdefer result.deinit(alloc);
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // OpEntryPoint: filter interface IDs
        if (op == 15 and wc >= 4) {
            // Find end of name string (null-terminated word)
            var str_end: u32 = pos + 3;
            var found_null = false;
            while (str_end < ie) : (str_end += 1) {
                const sw = words[str_end];
                if ((sw & 0xFF) == 0 or ((sw >> 8) & 0xFF) == 0 or
                    ((sw >> 16) & 0xFF) == 0 or ((sw >> 24) & 0xFF) == 0) {
                    found_null = true;
                    str_end += 1; // include this word
                    break;
                }
            }
            if (!found_null) str_end = ie;

            // Collect filtered interface IDs
            var filtered_ids = std.ArrayListUnmanaged(u32).empty;
            defer filtered_ids.deinit(alloc);
            var ip: u32 = str_end;
            while (ip < ie) : (ip += 1) {
                const iid = words[ip];
                if (!unused.contains(iid)) {
                    try filtered_ids.append(alloc, iid);
                }
            }

            // Emit new OpEntryPoint with updated word count
            const new_wc: u32 = @intCast(str_end - pos + filtered_ids.items.len);
            try result.append(alloc, (new_wc << 16) | 15);
            try result.append(alloc, words[pos + 1]); // execution model
            try result.append(alloc, words[pos + 2]); // func id
            // Copy name string
            ip = pos + 3;
            while (ip < str_end) : (ip += 1) {
                try result.append(alloc, words[ip]);
            }
            // Copy filtered interface IDs
            try result.appendSlice(alloc, filtered_ids.items);
            pos = ie;
            continue;
        }

        // Skip OpName for unused
        if (op == 5 and wc >= 3 and unused.contains(words[pos + 1])) { pos = ie; continue; }
        // Skip OpDecorate for unused
        if (op == 71 and wc >= 3 and unused.contains(words[pos + 1])) { pos = ie; continue; }
        // Skip OpVariable for unused
        if (op == 59 and wc >= 4 and unused.contains(words[pos + 2])) { pos = ie; continue; }

        try result.appendSlice(alloc, words[pos..ie]);
        pos = ie;
    }

    return result.toOwnedSlice(alloc) catch return words;
}

/// Remove OpName, OpMemberName, OpDecorate, OpMemberDecorate for IDs that are not
/// referenced by any non-debug instruction. Cleans up dead type info after global variable removal.
pub fn stripDeadDebugInfo(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find IDs referenced by non-debug instructions
    var live = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer live.deinit();
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        // Skip debug/decoration
        if (op == 5 or op == 6 or op == 71 or op == 72) { pos = ie; continue; }
        const info = compact_ids.getOpInfo(op) orelse { pos = ie; continue; };
        var wi: u32 = pos + 1;
        switch (info.fixed) {
            1 => { if (wi < ie and words[wi] < bound) live.set(words[wi]); wi += 1; },
            2 => { if (wi < ie and words[wi] < bound) live.set(words[wi]); wi += 1; if (wi < ie) wi += 1; },
            3 => { if (wi < ie) wi += 1; },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { if (words[wi] < bound) live.set(words[wi]); wi += 1; },
                'l' => { wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) { if (words[wi] < bound) live.set(words[wi]); } },
                'L', 's' => { wi = ie; },
                'M' => { if (wi < ie) wi += 1; while (wi < ie) : (wi += 1) { if (words[wi] < bound) live.set(words[wi]); } },
                'W' => { while (wi + 1 < ie) { wi += 1; if (words[wi] < bound) live.set(words[wi]); wi += 1; } if (wi < ie) wi += 1; },
                'E' => {
                    while (wi < ie) : (wi += 1) {
                        const sw = words[wi];
                        if ((sw & 0xFF) == 0 or ((sw >> 8) & 0xFF) == 0 or
                            ((sw >> 16) & 0xFF) == 0 or ((sw >> 24) & 0xFF) == 0) break;
                    }
                    while (wi < ie) : (wi += 1) { if (words[wi] < bound) live.set(words[wi]); }
                },
                else => { wi += 1; },
            }
        }
        pos = ie;
    }

    // Phase 2: Remove debug/decoration for non-live IDs
    var result = try std.ArrayList(u32).initCapacity(alloc, words.len);
    errdefer result.deinit(alloc);
    result.appendSliceAssumeCapacity(words[0..5]);
    var removed: u32 = 0;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const op: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        var skip = false;
        if ((op == 5 or op == 71) and wc >= 3) {
            const t = words[pos + 1];
            if (t > 0 and t < bound and !live.isSet(t)) skip = true;
        }
        if ((op == 6 or op == 72) and wc >= 4) {
            const t = words[pos + 1];
            if (t > 0 and t < bound and !live.isSet(t)) skip = true;
        }
        if (skip) { removed += 1; pos = ie; continue; }
        try result.appendSlice(alloc, words[pos..ie]);
        pos = ie;
    }
    if (removed == 0) { result.deinit(alloc); return words; }
    return result.toOwnedSlice(alloc) catch return words;
}

/// Deduplicate OpTypeFunction instructions with identical signatures.
pub fn dedupFunctionTypes(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Use a simple map: signature hash -> first result ID
    // Since signatures can be variable length, hash the full tuple
    var seen = std.AutoHashMapUnmanaged(u64, u32).empty; // hash -> first_id
    defer seen.deinit(alloc);
    var replacements = std.AutoHashMapUnmanaged(u32, u32).empty; // dup_id -> first_id
    defer replacements.deinit(alloc);

    // First pass: find duplicate function types (OpTypeFunction = opcode 33)
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 33 and wc >= 3) {
            const result_id = words[pos + 1];
            // Hash: return_type + all param types
            var h: u64 = 0;
            for (2..wc) |i| {
                h = h *% 33 +% @as(u64, words[pos + i]);
            }
            if (seen.get(h)) |first_id| {
                if (first_id != result_id) {
                    try replacements.put(alloc, result_id, first_id);
                }
            } else {
                try seen.put(alloc, h, result_id);
            }
        }
        pos += wc;
    }

    if (replacements.count() == 0) return words;

    // Second pass: skip duplicates, replace all references
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;

        // Skip duplicate OpTypeFunction
        if (opcode == 33 and wc >= 3 and replacements.contains(words[pos + 1])) {
            pos = ie;
            continue;
        }

        // Replace references in all instructions
        if (replacements.count() > 0) {
            const info = compact_ids.getOpInfo(opcode) orelse {
                result.appendSlice(alloc, words[pos..ie]) catch return words;
                pos = ie; continue;
            };
            var wi: u32 = pos + 1;
            try result.append(alloc, hdr);
            switch (info.fixed) {
                1 => { if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; } },
                2 => {
                    if (wi < ie) { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; }
                    if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
                },
                3 => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
                else => {},
            }
            for (info.ops) |ch| {
                if (wi >= ie) break;
                switch (ch) {
                    'i' => { try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; },
                    'l' => { try result.append(alloc, words[wi]); wi += 1; },
                    'I' => { while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                    'L', 's' => { while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]); },
                    'M' => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); },
                    'W' => { while (wi + 1 < ie) { try result.append(alloc, words[wi]); wi += 1; try result.append(alloc, replacements.get(words[wi]) orelse words[wi]); wi += 1; } if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
                    'E' => {
                        while (wi < ie) : (wi += 1) {
                            try result.append(alloc, words[wi]);
                            const sw = words[wi];
                            if ((sw & 0xFF) == 0 or ((sw >> 8) & 0xFF) == 0 or ((sw >> 16) & 0xFF) == 0 or ((sw >> 24) & 0xFF) == 0) break;
                        }
                        while (wi < ie) : (wi += 1) try result.append(alloc, replacements.get(words[wi]) orelse words[wi]);
                    },
                    else => { try result.append(alloc, words[wi]); wi += 1; },
                }
            }
            while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]);
        } else {
            try result.appendSlice(alloc, words[pos..ie]);
        }
        pos = ie;
    }

    return result.toOwnedSlice(alloc) catch return words;
}

/// Ensure type definitions come before constants in the non-function section.
/// The optimization pipeline may reorder instructions, placing OpVariable before types.
/// This pass scans non-function instructions and reorders: preamble → types → constants → globals.
pub fn fixTypeOrdering(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return alloc.dupe(u32, words);

    var preamble = std.ArrayList(u32).initCapacity(alloc, words.len) catch return alloc.dupe(u32, words);
    var debug_sec = std.ArrayList(u32).initCapacity(alloc, words.len) catch return alloc.dupe(u32, words);
    var annot_sec = std.ArrayList(u32).initCapacity(alloc, words.len) catch return alloc.dupe(u32, words);
    var type_sec = std.ArrayList(u32).initCapacity(alloc, words.len) catch return alloc.dupe(u32, words);
    var const_sec = std.ArrayList(u32).initCapacity(alloc, words.len) catch return alloc.dupe(u32, words);
    var global_sec = std.ArrayList(u32).initCapacity(alloc, words.len) catch return alloc.dupe(u32, words);
    var func_sec = std.ArrayList(u32).initCapacity(alloc, words.len) catch return alloc.dupe(u32, words);
    defer {
        preamble.deinit(alloc); debug_sec.deinit(alloc); annot_sec.deinit(alloc);
        type_sec.deinit(alloc); const_sec.deinit(alloc); global_sec.deinit(alloc); func_sec.deinit(alloc);
    }

    preamble.appendSliceAssumeCapacity(words[0..5]);

    var pos: u32 = 5;
    var in_func = false;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        const inst = words[pos..ie];

        if (opcode == 54) in_func = true; // OpFunction
        if (opcode == 56) { // OpFunctionEnd
            func_sec.appendSliceAssumeCapacity(inst);
            in_func = false;
            pos = ie;
            continue;
        }
        if (in_func) {
            func_sec.appendSliceAssumeCapacity(inst);
            pos = ie;
            continue;
        }

        // Categorize non-function instructions
        switch (opcode) {
            17, 18, 11, 14, 15, 16 => preamble.appendSliceAssumeCapacity(inst),
            3, 4, 5, 6, 7, 8 => debug_sec.appendSliceAssumeCapacity(inst),
            71, 72, 73, 74, 75, 76 => annot_sec.appendSliceAssumeCapacity(inst),
            41, 42, 50 => const_sec.appendSliceAssumeCapacity(inst), // OpConstantTrue/False/Null
            43, 44 => const_sec.appendSliceAssumeCapacity(inst), // OpConstant/Composite
            59 => global_sec.appendSliceAssumeCapacity(inst), // OpVariable (non-function — these are globals)
            else => {
                // Everything else that's not a constant or variable goes to types
                // This includes OpType* (19-33), OpTypeForwardPointer (39), etc.
                type_sec.appendSliceAssumeCapacity(inst);
            },
        }
        pos = ie;
    }

    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return alloc.dupe(u32, words);
    result.appendSliceAssumeCapacity(preamble.items);
    result.appendSliceAssumeCapacity(debug_sec.items);
    result.appendSliceAssumeCapacity(annot_sec.items);
    result.appendSliceAssumeCapacity(type_sec.items);
    result.appendSliceAssumeCapacity(const_sec.items);
    result.appendSliceAssumeCapacity(global_sec.items);
    result.appendSliceAssumeCapacity(func_sec.items);
    return result.toOwnedSlice(alloc) catch return alloc.dupe(u32, words);
}

/// Fold OpBranchConditional with constant boolean conditions to unconditional OpBranch.
/// Also removes the associated OpSelectionMerge when the branch becomes unconditional.
pub fn foldConstBranches(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find bool type and true/false constants
    var bool_type: u32 = 0;
    var true_id: u32 = 0;
    var false_id: u32 = 0;

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 20 and wc >= 2) bool_type = words[pos + 1]; // OpTypeBool
        if (opcode == 41 and wc >= 3 and words[pos + 1] == bool_type) true_id = words[pos + 2]; // OpConstantTrue
        if (opcode == 42 and wc >= 3 and words[pos + 1] == bool_type) false_id = words[pos + 2]; // OpConstantFalse
        pos += wc;
    }

    if (true_id == 0 and false_id == 0) return words;

    // Phase 2: Find foldable OpBranchConditional instructions
    // An OpBranchConditional with constant condition can become OpBranch.
    // Build set of positions to fold.
    var fold_positions = std.AutoHashMapUnmanaged(u32, u32).empty; // position -> target label
    defer fold_positions.deinit(alloc);
    // Also track associated SelectionMerge positions to remove
    var merge_positions = std.AutoHashMapUnmanaged(u32, void).empty; // position of SelectionMerge to remove
    defer merge_positions.deinit(alloc);

    pos = 5;
    var prev_pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 250 and wc >= 4) { // OpBranchConditional
            const cond = words[pos + 1];
            const true_label = words[pos + 2];
            const false_label = words[pos + 3];
            if (cond == true_id) {
                fold_positions.put(alloc, pos, true_label) catch {};
                // Find associated SelectionMerge (should be just before this in the same block)
                // Walk backwards from this position to find SelectionMerge
                var pp: u32 = prev_pos;
                while (pp < pos) {
                    const ph = words[pp];
                    const pw: u32 = ph >> 16;
                    const pop: u16 = @truncate(ph & 0xFFFF);
                    if (pw == 0) break;
                    if (pop == 247) { // OpSelectionMerge
                        merge_positions.put(alloc, pp, {}) catch {};
                        break;
                    }
                    pp += pw;
                }
            } else if (cond == false_id) {
                fold_positions.put(alloc, pos, false_label) catch {};
                var pp: u32 = prev_pos;
                while (pp < pos) {
                    const ph = words[pp];
                    const pw: u32 = ph >> 16;
                    const pop: u16 = @truncate(ph & 0xFFFF);
                    if (pw == 0) break;
                    if (pop == 247) { // OpSelectionMerge
                        merge_positions.put(alloc, pp, {}) catch {};
                        break;
                    }
                    pp += pw;
                }
            }
        }

        // Track label boundaries for finding SelectionMerge
        if (opcode == 248 and wc >= 2) { // OpLabel
            prev_pos = pos;
        }

        pos = ie;
    }

    if (fold_positions.count() == 0) return words;

    // Phase 3: Rewrite — remove SelectionMerge, replace OpBranchConditional with OpBranch
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip SelectionMerge instructions that are being removed
        if (merge_positions.contains(pos)) {
            pos = ie;
            continue;
        }

        // Replace foldable OpBranchConditional with OpBranch
        if (fold_positions.get(pos)) |target| {
            result.append(alloc, (2 << 16) | 249) catch return words; // OpBranch
            result.append(alloc, target) catch return words;
            pos = ie;
            continue;
        }

        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }
    return result.toOwnedSlice(alloc) catch return alloc.dupe(u32, words);
}

/// Eliminate unreachable blocks: blocks that are never targeted by any OpBranch, OpBranchConditional,
/// OpSwitch, or OpLoopMerge. After foldConstBranches removes conditional branches, the dead branch
/// target becomes unreachable and its instructions can be removed.
pub fn elimUnreachableBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build map of label_id -> position of OpLabel instruction
    var label_pos = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer label_pos.deinit(alloc);
    // Also collect function entry labels
    var func_entries = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer func_entries.deinit();
    var in_function = false;
    var first_label = true;

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        switch (opcode) {
            54 => { in_function = true; first_label = true; },
            56 => { in_function = false; },
            248 => if (wc >= 2) {
                const lbl = words[pos + 1];
                label_pos.put(alloc, lbl, pos) catch {};
                if (in_function and first_label and lbl >= 1 and lbl < bound) {
                    func_entries.set(lbl);
                    first_label = false;
                }
            },
            else => {},
        }
        pos = ie;
    }

    // Phase 2: Forward reachability analysis
    // Start from function entry labels, follow branches transitively
    var reachable = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer reachable.deinit();

    // Seed with function entry labels
    var fei = func_entries.iterator(.{});
    while (fei.next()) |idx| reachable.set(idx);

    // Iteratively discover reachable blocks
    var changed = true;
    while (changed) {
        changed = false;
        var ri = reachable.iterator(.{});
        while (ri.next()) |lbl| {
            // Find the block starting at this label and scan for branch instructions
            const lp = label_pos.get(@intCast(lbl)) orelse continue;
            var bp: u32 = lp;
            while (bp < words.len) {
                const bhdr = words[bp];
                const bwc: u32 = bhdr >> 16;
                const bop: u16 = @truncate(bhdr & 0xFFFF);
                if (bwc == 0) break;
                const bie = bp + bwc;
                if (bie > words.len) break;

                if (bop == 248 and bp != lp) break; // Hit next block

                switch (bop) {
                    249 => { // OpBranch
                        if (bwc >= 2) {
                            const t = words[bp + 1];
                            if (t >= 1 and t < bound and !reachable.isSet(t)) { reachable.set(t); changed = true; }
                        }
                    },
                    250 => { // OpBranchConditional
                        if (bwc >= 4) {
                            const t1 = words[bp + 2]; const t2 = words[bp + 3];
                            if (t1 >= 1 and t1 < bound and !reachable.isSet(t1)) { reachable.set(t1); changed = true; }
                            if (t2 >= 1 and t2 < bound and !reachable.isSet(t2)) { reachable.set(t2); changed = true; }
                        }
                    },
                    251 => { // OpSwitch
                        if (bwc >= 3) {
                            const dt = words[bp + 2];
                            if (dt >= 1 and dt < bound and !reachable.isSet(dt)) { reachable.set(dt); changed = true; }
                            var si: u32 = bp + 3;
                            while (si + 1 < bie) : (si += 2) {
                                const ct = words[si + 1];
                                if (ct >= 1 and ct < bound and !reachable.isSet(ct)) { reachable.set(ct); changed = true; }
                            }
                        }
                    },
                    246 => { // OpLoopMerge — merge and continue targets are reachable
                        if (bwc >= 3) {
                            const m = words[bp + 1]; const c = words[bp + 2];
                            if (m >= 1 and m < bound and !reachable.isSet(m)) { reachable.set(m); changed = true; }
                            if (c >= 1 and c < bound and !reachable.isSet(c)) { reachable.set(c); changed = true; }
                        }
                    },
                    247 => { // OpSelectionMerge
                        if (bwc >= 2) {
                            const m = words[bp + 1];
                            if (m >= 1 and m < bound and !reachable.isSet(m)) { reachable.set(m); changed = true; }
                        }
                    },
                    245 => { // OpPhi: parent labels are structural predecessors — keep them
                        var pi: u32 = bp + 3;
                        while (pi + 1 < bie) : (pi += 2) {
                            const p = words[pi + 1];
                            if (p >= 1 and p < bound and !reachable.isSet(p)) { reachable.set(p); changed = true; }
                        }
                    },
                    else => {},
                }
                bp = bie;
            }
        }
    }

    // Phase 3: Find unreachable labels
    var unreachable_labels = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer unreachable_labels.deinit();

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 248 and wc >= 2) {
            const lbl = words[pos + 1];
            if (lbl >= 1 and lbl < bound and !reachable.isSet(lbl)) {
                unreachable_labels.set(lbl);
            }
        }
        pos = ie;
    }

    if (unreachable_labels.count() == 0) return words;

    // Phase 4: Remove unreachable blocks + fix OpPhi entries referencing removed labels
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    var in_unreachable = false;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 248 and wc >= 2) { // OpLabel
            const lbl = words[pos + 1];
            if (lbl >= 1 and lbl < bound and unreachable_labels.isSet(lbl)) {
                in_unreachable = true;
                pos = ie;
                continue;
            }
            in_unreachable = false;
        }

        if (in_unreachable) { pos = ie; continue; }

        // Fix OpPhi: remove entries whose parent label was removed
        if (opcode == 245 and wc >= 5) { // OpPhi
            var phi_buf = std.ArrayListUnmanaged(u32).initCapacity(alloc, wc) catch {
                result.appendSlice(alloc, words[pos..ie]) catch return words;
                pos = ie;
                continue;
            };
            phi_buf.appendAssumeCapacity(words[pos + 1]); // result type
            phi_buf.appendAssumeCapacity(words[pos + 2]); // result id
            var phi_ok = true;
            var pi: u32 = pos + 3;
            while (pi + 1 < ie) : (pi += 2) {
                const val = words[pi];
                const parent = words[pi + 1];
                if (parent >= 1 and parent < bound and unreachable_labels.isSet(parent)) {
                    continue; // parent removed, skip entry
                }
                phi_buf.append(alloc, val) catch { phi_ok = false; break; };
                phi_buf.append(alloc, parent) catch { phi_ok = false; break; };
            }
            if (phi_ok and phi_buf.items.len >= 4) {
                // Emit fixed OpPhi with only valid entries
                // Single-entry phis will be cleaned up by simplifyTrivialPhi
                const new_wc: u32 = @intCast(phi_buf.items.len + 1);
                result.append(alloc, (new_wc << 16) | 245) catch return words;
                result.appendSlice(alloc, phi_buf.items) catch return words;
            } else if (!phi_ok) {
                // OOM in phi_buf, emit original
                result.appendSlice(alloc, words[pos..ie]) catch return words;
            }
            // If phi has no valid entries (phi_buf.items.len < 4), omit it (DCE will clean up)
            phi_buf.deinit(alloc);
            pos = ie;
            continue;
        }

        result.appendSlice(alloc, words[pos..ie]) catch return words;
        pos = ie;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }
    return result.toOwnedSlice(alloc) catch return alloc.dupe(u32, words);
}

/// Fold OpCompositeExtract from OpConstantComposite into the constant component.
/// Unlike foldCompositeExtract (which handles runtime OpCompositeConstruct), this pass
/// only handles constants and uses simple ID mapping without ArrayList allocations.
pub fn foldConstCompositeExtract(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build map of OpConstantComposite: result_id -> start_pos, component_count
    var const_comp = std.AutoHashMapUnmanaged(u32, struct { start: u32, count: u32 }).empty;
    defer const_comp.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        // OpConstantComposite = 44, format: type_id, result_id, constituent...
        if (opcode == 44 and wc >= 4) {
            const result_id = words[pos + 2];
            const_comp.put(alloc, result_id, .{ .start = pos + 3, .count = wc - 3 }) catch {};
        }
        pos = ie;
    }

    if (const_comp.count() == 0) return words;

    // Phase 2: Find OpCompositeExtract from constant composites and build replacement map
    var replacements = std.AutoHashMapUnmanaged(u32, u32).empty; // extract_result_id -> component_id
    defer replacements.deinit(alloc);
    var to_skip = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer to_skip.deinit();

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // OpCompositeExtract = 81, format: type_id, result_id, composite_id, index_literals...
        if (opcode == 81 and wc >= 5) {
            const result_id = words[pos + 2];
            const composite_id = words[pos + 3];
            const index = words[ie - 1]; // last word is the (first) index
            if (result_id >= 1 and result_id < bound) {
                if (const_comp.get(composite_id)) |cc| {
                    // Single-level extract only (wc == 5 means one index)
                    if (wc == 5 and index < cc.count) {
                        const component_id = words[cc.start + index];
                        replacements.put(alloc, result_id, component_id) catch {};
                        to_skip.set(result_id);
                    }
                }
            }
        }
        pos = ie;
    }

    if (replacements.count() == 0) return words;

    // Phase 3: Rewrite — skip folded extracts, replace operand references
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip folded extracts
        if (opcode == 81 and wc >= 3 and words[pos + 2] < bound and to_skip.isSet(words[pos + 2])) {
            pos = ie;
            continue;
        }

        // Rewrite operand references
        const info = compact_ids.getOpInfo(opcode) orelse {
            result.append(alloc, hdr) catch return words;
            var wi: u32 = pos + 1;
            while (wi < ie) : (wi += 1) {
                result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words;
            }
            pos = ie;
            continue;
        };

        result.append(alloc, hdr) catch return words;
        var wi: u32 = pos + 1;
        switch (info.fixed) {
            0 => {},
            1 => { if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } },
            2 => {
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } // skip result
            },
            3 => { if (wi < ie) { result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; wi += 1; },
                'l' => { result.append(alloc, words[wi]) catch return words; wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; },
                'L', 's' => { while (wi < ie) : (wi += 1) result.append(alloc, words[wi]) catch return words; },
                'M' => {
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                    while (wi < ie) : (wi += 1) result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words;
                },
                'W' => {
                    while (wi + 1 < ie) {
                        result.append(alloc, words[wi]) catch return words; // literal
                        wi += 1;
                        result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; // target
                        wi += 1;
                    }
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                },
                'E' => {
                    while (wi < ie) {
                        const w = words[wi]; result.append(alloc, w) catch return words; wi += 1;
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break;
                    }
                    while (wi < ie) : (wi += 1) result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words;
                },
                else => { result.append(alloc, words[wi]) catch return words; wi += 1; },
            }
        }
        // Append any remaining words
        while (wi < ie) : (wi += 1) {
            result.append(alloc, words[wi]) catch return words;
        }
        pos = ie;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }
    return result.toOwnedSlice(alloc) catch return alloc.dupe(u32, words);
}

pub fn simplifyTrivialPhi(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find OpPhi instructions where all incoming values are the same ID
    var replacements = std.AutoHashMapUnmanaged(u32, u32).empty; // phi_result_id -> replacement_id
    defer replacements.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // OpPhi: opcode 245, format: type result (value parent)+
        // Minimum: wc=5 (type, result, value, parent)
        if (opcode == 245 and wc >= 5) {
            const result_id = words[pos + 2];
            // Check if all values are the same
            const first_val = words[pos + 3];
            var all_same = true;
            var pi: u32 = pos + 5; // skip first (value, parent) pair
            while (pi + 1 < ie) : (pi += 2) {
                if (words[pi] != first_val) {
                    all_same = false;
                    break;
                }
            }
            if (all_same and first_val > 0 and first_val < bound) {
                try replacements.put(alloc, result_id, first_val);
            }
        }
        pos = ie;
    }

    if (replacements.count() == 0) return words;

    // Resolve transitive chains (phi A -> phi B -> val)
    var changed = true;
    while (changed) {
        changed = false;
        var it = replacements.iterator();
        while (it.next()) |entry| {
            if (replacements.get(entry.value_ptr.*)) |resolved| {
                if (entry.value_ptr.* != resolved) {
                    entry.value_ptr.* = resolved;
                    changed = true;
                }
            }
        }
    }

    // Phase 2: Rewrite -- skip eliminated phis, substitute references
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip eliminated phi instructions
        if (opcode == 245 and wc >= 3 and replacements.contains(words[pos + 2])) {
            pos = ie;
            continue;
        }

        // Apply substitution to operands using getOpInfo
        const info = compact_ids.getOpInfo(opcode) orelse {
            // Unknown opcode: substitute all words
            result.append(alloc, hdr) catch return words;
            var wi2: u32 = pos + 1;
            while (wi2 < ie) : (wi2 += 1) {
                result.append(alloc, replacements.get(words[wi2]) orelse words[wi2]) catch return words;
            }
            pos = ie;
            continue;
        };

        result.append(alloc, hdr) catch return words;
        var wi: u32 = pos + 1;
        switch (info.fixed) {
            0 => {},
            1 => { if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } },
            2 => {
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
            },
            3 => { if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => {
                    result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words;
                    wi += 1;
                },
                'I' => { while (wi < ie) : (wi += 1) {
                    result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words;
                }},
                'l' => { if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; } },
                'L' => { wi = ie; },
                's' => { wi = ie; },
                'M' => {
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                    while (wi < ie) : (wi += 1) {
                        result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words;
                    }
                },
                'W' => {
                    while (wi + 1 < ie) {
                        result.append(alloc, words[wi]) catch return words; // literal
                        wi += 1;
                        result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words; // target
                        wi += 1;
                    }
                    if (wi < ie) { result.append(alloc, words[wi]) catch return words; wi += 1; }
                },
                'E' => {
                    while (wi < ie) {
                        const w = words[wi];
                        result.append(alloc, w) catch return words;
                        wi += 1;
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break;
                    }
                    while (wi < ie) : (wi += 1) {
                        result.append(alloc, replacements.get(words[wi]) orelse words[wi]) catch return words;
                    }
                },
                else => { result.append(alloc, words[wi]) catch return words; wi += 1; },
            }
        }
        // Copy any remaining words
        while (wi < ie) : (wi += 1) {
            result.append(alloc, words[wi]) catch return words;
        }
        pos = ie;
    }

    if (result.items.len == words.len) {
        result.deinit(alloc);
        return words;
    }
    return result.toOwnedSlice(alloc) catch return alloc.dupe(u32, words);
}
