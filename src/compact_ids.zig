// SPIR-V ID compaction pass.
// Remaps IDs to eliminate gaps in the ID space, reducing the Bound header field.
// Generated from SPIR-V 1.5 grammar with manual corrections for image operands.
const std = @import("std");

const OpInfo = struct {
    /// Number of words before the first operand (after the header word).
    /// 1 = has result_type only (at word 1)
    /// 2 = has result_type + result (at words 1 and 2)
    /// 0 = has result only (at word 1)
    /// Use values: 0=nothing, 1=result_type, 2=result_type+result, 3=result_only
    fixed: u8,
    /// For each operand after the fixed part:
    /// 'i' = ID (1 word)
    /// 'l' = literal (1 word, NOT an ID)
    /// 'I' = rest of words are all IDs
    /// 'L' = rest of words are all literals
    /// 's' = string (consume rest, NOT IDs)
    /// 'M' = image operands: mask literal, then IDs for rest
    /// 'W' = switch: pairs of (literal, ID) for rest
    ops: []const u8,
};

inline fn rt(id_count: u8, comptime ops: []const u8) OpInfo {
    return .{ .fixed = id_count, .ops = ops };
}

fn getOpInfo(opcode: u16) ?OpInfo {
    // fixed: 0=none, 1=result_type, 2=result_type+result, 3=result_only
    return switch (opcode) {
        // --- Core ---
        3 => rt(0, "lls"),         // OpSource: lang, ver, [file(id), source(str)] -- simplified: treat file as lit
        5 => rt(0, "is"),          // OpName
        6 => rt(0, "ils"),         // OpMemberName
        10 => rt(0, "s"),          // OpExtension
        11 => rt(3, "s"),          // OpExtInstImport (result_only)
        12 => rt(2, "ilI"),        // OpExtInst
        14 => rt(0, "ll"),         // OpMemoryModel
        15 => rt(0, "liE"),        // OpEntryPoint: model, func-id, [name string + interface ids]
        16 => rt(0, "ilL"),        // OpExecutionMode (may have extra literals)
        17 => rt(0, "l"),          // OpCapability
        // --- Type ---
        19 => rt(3, ""),           // OpTypeVoid (result_only)
        20 => rt(3, ""),           // OpTypeBool
        21 => rt(3, "ll"),         // OpTypeInt
        22 => rt(3, "ll"),         // OpTypeFloat
        23 => rt(3, "il"),         // OpTypeVector: element-type, count
        24 => rt(3, "il"),         // OpTypeMatrix
        25 => rt(3, "illlllil"),   // OpTypeImage: type, dim, depth, arrayed, ms, sampled, fmt, access
        26 => rt(3, ""),           // OpTypeSampler
        27 => rt(3, "i"),          // OpTypeSampledImage
        28 => rt(3, "ii"),         // OpTypeArray: element-type, length-id
        29 => rt(3, "i"),          // OpTypeRuntimeArray
        30 => rt(3, "I"),          // OpTypeStruct: member-types...
        32 => rt(3, "li"),         // OpTypePointer: sc, type
        33 => rt(3, "iI"),         // OpTypeFunction: return-type, param-types...
        39 => rt(0, "il"),         // OpTypeForwardPointer
        // --- Constant ---
        41 => rt(2, ""),           // OpConstantTrue
        42 => rt(2, ""),           // OpConstantFalse
        43 => rt(2, "l"),          // OpConstant (value may be multi-word for 64-bit)
        44 => rt(2, "I"),          // OpConstantComposite: constituents...
        50 => rt(2, "l"),          // OpSpecConstant
        // --- Function ---
        54 => rt(2, "li"),         // OpFunction: control, func-type
        55 => rt(2, ""),           // OpFunctionParameter
        56 => rt(0, ""),           // OpFunctionEnd
        57 => rt(2, "iI"),         // OpFunctionCall: func, args...
        // --- Memory ---
        59 => rt(2, "li"),         // OpVariable: sc, optional-init-id
        60 => rt(2, "iiI"),        // OpImageTexelPointer
        61 => rt(2, "iL"),          // OpLoad: ptr, optional-mem-access-literals
        62 => rt(0, "iiL"),         // OpStore: ptr, obj, optional-mem-access
        65 => rt(2, "iI"),         // OpAccessChain: base, indexes...
        // --- Decoration ---
        71 => rt(0, "ilL"),        // OpDecorate: target-id, decoration, extra-literals
        72 => rt(0, "illL"),       // OpMemberDecorate: type-id, member, decoration, extra-literals
        // --- Composite ---
        77 => rt(2, "ii"),         // OpVectorExtractDynamic: vec, index
        79 => rt(2, "iiL"),        // OpVectorShuffle: vec1, vec2, literal-components...
        80 => rt(2, "I"),          // OpCompositeConstruct: constituents...
        81 => rt(2, "iL"),         // OpCompositeExtract: composite, literal-indexes...
        // --- Image ---
        84 => rt(2, "i"),          // OpTranspose
        86 => rt(2, "ii"),         // OpSampledImage
        87 => rt(2, "iiM"),        // OpImageSampleImplicitLod: sampled, coord, [img-ops]
        88 => rt(2, "iiM"),        // OpImageSampleExplicitLod: sampled, coord, img-ops(mask+IDs)
        89 => rt(2, "iiiM"),       // OpImageSampleDrefImplicitLod: sampled, coord, dref, [img-ops]
        90 => rt(2, "iiiM"),        // OpImageSampleDrefExplicitLod: sampled, coord, dref, img-ops
        91 => rt(2, "iiM"),        // OpImageSampleProjImplicitLod
        93 => rt(2, "iiii"),       // OpImageSampleProjDrefImplicitLod
        95 => rt(2, "iiM"),        // OpImageFetch: image, coord, [img-ops]
        96 => rt(2, "iii"),        // OpImageGather: sampled, coord, component
        97 => rt(2, "iiii"),       // OpImageDrefGather
        98 => rt(2, "iiM"),        // OpImageRead: image, coord, [img-ops]
        99 => rt(0, "iiiM"),       // OpImageWrite: image, coord, texel, [img-ops]
        100 => rt(2, "i"),         // OpImage: sampled-image
        103 => rt(2, "ii"),        // OpImageQuerySizeLod
        104 => rt(2, "i"),         // OpImageQuerySize
        105 => rt(2, "ii"),        // OpImageQueryLod
        106 => rt(2, "i"),         // OpImageQueryLevels
        107 => rt(2, "i"),         // OpImageQuerySamples
        // --- Conversion ---
        109 => rt(2, "i"),         // OpConvertFToU
        110 => rt(2, "i"),         // OpConvertFToS
        111 => rt(2, "i"),         // OpConvertSToF
        112 => rt(2, "i"),         // OpConvertUToF
        114 => rt(2, "i"),         // OpSConvert
        124 => rt(2, "i"),         // OpBitcast
        // --- Arithmetic ---
        126 => rt(2, "i"),         // OpSNegate
        127 => rt(2, "i"),         // OpFNegate
        128...133 => rt(2, "ii"),  // OpIAdd..OpFMul
        135 => rt(2, "ii"),        // OpSDiv
        136 => rt(2, "ii"),        // OpFDiv
        137 => rt(2, "ii"),        // OpUMod
        138 => rt(2, "ii"),        // OpSRem
        141 => rt(2, "ii"),        // OpFMod
        142 => rt(2, "ii"),        // OpVectorTimesScalar
        144...148 => rt(2, "ii"),  // OpVectorTimesMatrix..OpDot
        // --- Relational ---
        154...155 => rt(2, "i"),   // OpAll, OpAny
        156...157 => rt(2, "i"),   // OpIsNan, OpIsInf
        166...168 => rt(2, "ii"),  // OpLogicalOr, OpLogicalAnd, OpLogicalNot (168 is unary)
        169 => rt(2, "iii"),       // OpSelect
        170...171 => rt(2, "ii"),  // OpIEqual, OpINotEqual
        173 => rt(2, "ii"),        // OpSGreaterThan
        177 => rt(2, "ii"),        // OpSLessThan
        180 => rt(2, "ii"),        // OpFOrdEqual
        182 => rt(2, "ii"),        // OpFOrdNotEqual
        184 => rt(2, "ii"),        // OpFOrdLessThan
        186 => rt(2, "ii"),        // OpFOrdGreaterThan
        // --- Bit ---
        196 => rt(2, "ii"),        // OpShiftLeftLogical
        198...199 => rt(2, "ii"),  // OpBitwiseXor, OpBitwiseAnd
        200 => rt(2, "i"),         // OpNot
        // --- Derivatives ---
        207...215 => rt(2, "i"),   // OpDPdx..OpFwidthCoarse
        // --- Atomic ---
        224 => rt(0, "iii"),       // OpControlBarrier: exec-scope, mem-scope, semantics
        225 => rt(0, "ii"),        // OpMemoryBarrier: scope, semantics
        229 => rt(2, "iiii"),      // OpAtomicExchange: ptr, scope, semantics, value
        230 => rt(2, "iiiiii"),    // OpAtomicCompareExchange: ptr, scope, eq-sem, neq-sem, val, cmp
        234 => rt(2, "iiii"),      // OpAtomicIAdd: ptr, scope, sem, value
        236...242 => rt(2, "iiii"),// OpAtomicSMin..OpAtomicXor
        // --- Control Flow ---
        246 => rt(0, "iil"),       // OpLoopMerge: merge, continue, control
        247 => rt(0, "il"),        // OpSelectionMerge: merge, control
        248 => rt(3, ""),           // OpLabel (result_only)
        249 => rt(0, "i"),          // OpBranch: target
        250 => rt(0, "iiiL"),       // OpBranchConditional: cond, true, false, optional-weights
        251 => rt(0, "iiW"),        // OpSwitch: selector, default, (literal, target)...
        252 => rt(0, ""),            // OpKill
        253 => rt(0, ""),            // OpReturn
        254 => rt(0, "i"),           // OpReturnValue: value
        255 => rt(0, ""),            // OpUnreachable
        // --- Vendor ---
        4163 => rt(3, "iii"),       // OpTypeTensorARM
        4164 => rt(2, "iil"),       // OpTensorReadARM
        4166 => rt(2, "ii"),        // OpTensorQuerySizeARM
        4428...4429 => rt(2, "i"),  // OpSubgroupAllKHR, OpSubgroupAnyKHR
        4472 => rt(3, ""),           // OpTypeRayQueryKHR (result_only)
        4473 => rt(0, "iiiiiiii"),   // OpRayQueryInitializeKHR
        4477 => rt(2, "i"),          // OpRayQueryProceedKHR
        4479 => rt(2, "ii"),         // OpRayQueryGetIntersectionTypeKHR
        4480...4481 => rt(2, "iii"), // OpImageSampleWeightedQCOM, OpImageBoxFilterQCOM
        4482...4483 => rt(2, "iiiii"), // OpImageBlockMatchSSDQCOM, OpImageBlockMatchSADQCOM
        5340 => rt(2, "ii"),         // OpRayQueryGetIntersectionTriangleVertexPositionsKHR
        5341 => rt(3, ""),            // OpTypeAccelerationStructureKHR (result_only)
        6035 => rt(2, "iiii"),        // OpAtomicFAddEXT

        else => null,
    };
}

/// Compact IDs in a SPIR-V binary. Eliminates gaps in the ID space.
pub fn compactIds(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return alloc.dupe(u32, words);

    // Phase 1: Walk all instructions, collect IDs at known-ID positions.
    // Use a bitset: bit N is set if ID N is used (defined or referenced) in the binary.
    var used = try std.DynamicBitSet.initEmpty(alloc, bound);
    defer used.deinit();

    // Helper: mark a word as a used ID if it's in range [1, bound)
    const mark = struct {
        fn markId(used_: *std.DynamicBitSet, w: u32, bnd: u32) void {
            if (w >= 1 and w < bnd) used_.set(w);
        }
    }.markId;

    // Walk instructions for phase 1
    var pos: u32 = 5; // skip 5-word header
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const inst_end = pos + wc;
        if (inst_end > words.len) break;

        const info = getOpInfo(opcode) orelse {
            // Unknown opcode: skip instruction entirely (don't mark anything)
            pos = inst_end;
            continue;
        };

        var wi: u32 = pos + 1; // word index, start after header

        // Fixed part
        switch (info.fixed) {
            1 => { // result_type at word 1
                if (wi < inst_end) { mark(&used, words[wi], bound); wi += 1; }
            },
            2 => { // result_type at word 1, result at word 2
                if (wi < inst_end) { mark(&used, words[wi], bound); wi += 1; }
                if (wi < inst_end) { mark(&used, words[wi], bound); wi += 1; }
            },
            3 => { // result only at word 1
                if (wi < inst_end) { mark(&used, words[wi], bound); wi += 1; }
            },
            else => {},
        }

        // Variable operands
        for (info.ops) |ch| {
            if (wi >= inst_end) break;
            switch (ch) {
                'i' => {
                    mark(&used, words[wi], bound);
                    wi += 1;
                },
                'l' => {
                    wi += 1;
                },
                'I' => {
                    while (wi < inst_end) : (wi += 1) {
                        mark(&used, words[wi], bound);
                    }
                },
                'L' => {
                    wi = inst_end;
                },
                's' => {
                    wi = inst_end;
                },
                'M' => {
                    // Image operands: mask(literal) then IDs
                    if (wi < inst_end) {
                        wi += 1; // skip mask literal
                        while (wi < inst_end) : (wi += 1) {
                            mark(&used, words[wi], bound);
                        }
                    }
                },
                'W' => {
                    // Switch: pairs of (literal, target-ID)
                    while (wi + 1 < inst_end) {
                        wi += 1; // skip literal
                        mark(&used, words[wi], bound);
                        wi += 1;
                    }
                    if (wi < inst_end) wi += 1; // trailing literal
                },
                'E' => {
                    // OpEntryPoint string + interface IDs
                    // Skip string words until we find a word with a null byte
                    while (wi < inst_end) {
                        const w = words[wi];
                        wi += 1;
                        // Check if any byte in this word is 0 (null terminator)
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) {
                            break;
                        }
                    }
                    // Rest are interface IDs
                    while (wi < inst_end) : (wi += 1) {
                        mark(&used, words[wi], bound);
                    }
                },
                else => {},
            }
        }
        pos = inst_end;
    }

    // Phase 2: Build mapping old_id -> new_id (sequential, no gaps)
    const mapping = try alloc.alloc(u32, bound);
    defer alloc.free(mapping);
    @memset(mapping, 0);

    var next_new: u32 = 1;
    for (1..bound) |old_id| {
        if (used.isSet(old_id)) {
            mapping[old_id] = next_new;
            next_new += 1;
        }
    }

    // If nothing to compact, return original
    if (next_new == bound) return alloc.dupe(u32, words);

    // Phase 3: Rewrite the binary
    var result = try std.ArrayList(u32).initCapacity(alloc, words.len);
    // Header: magic, version, generator, new_bound, schema
    try result.appendSlice(alloc, words[0..3]);
    try result.append(alloc, next_new);
    try result.append(alloc, words[4]);

    // Helper: remap an ID
    const remap = struct {
        fn remap(mapping_: []const u32, w: u32) u32 {
            return if (w > 0 and w < mapping_.len) mapping_[w] else w;
        }
    }.remap;

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const inst_end = pos + wc;
        if (inst_end > words.len) break;

        const info = getOpInfo(opcode) orelse {
            // Unknown opcode: copy as-is
            try result.appendSlice(alloc, words[pos..inst_end]);
            pos = inst_end;
            continue;
        };

        try result.append(alloc, hdr); // instruction header

        var wi: u32 = pos + 1;

        // Fixed part
        switch (info.fixed) {
            1 => {
                if (wi < inst_end) { try result.append(alloc, remap(mapping, words[wi])); wi += 1; }
            },
            2 => {
                if (wi < inst_end) { try result.append(alloc, remap(mapping, words[wi])); wi += 1; }
                if (wi < inst_end) { try result.append(alloc, remap(mapping, words[wi])); wi += 1; }
            },
            3 => {
                if (wi < inst_end) { try result.append(alloc, remap(mapping, words[wi])); wi += 1; }
            },
            else => {},
        }

        // Variable operands
        for (info.ops) |ch| {
            if (wi >= inst_end) break;
            switch (ch) {
                'i' => {
                    try result.append(alloc, remap(mapping, words[wi]));
                    wi += 1;
                },
                'l' => {
                    try result.append(alloc, words[wi]);
                    wi += 1;
                },
                'I' => {
                    while (wi < inst_end) : (wi += 1) {
                        try result.append(alloc, remap(mapping, words[wi]));
                    }
                },
                'L' => {
                    while (wi < inst_end) : (wi += 1) {
                        try result.append(alloc, words[wi]);
                    }
                },
                's' => {
                    while (wi < inst_end) : (wi += 1) {
                        try result.append(alloc, words[wi]);
                    }
                },
                'M' => {
                    if (wi < inst_end) {
                        try result.append(alloc, words[wi]); // mask literal
                        wi += 1;
                        while (wi < inst_end) : (wi += 1) {
                            try result.append(alloc, remap(mapping, words[wi]));
                        }
                    }
                },
                'W' => {
                    while (wi + 1 < inst_end) {
                        try result.append(alloc, words[wi]); // literal
                        wi += 1;
                        try result.append(alloc, remap(mapping, words[wi])); // target ID
                        wi += 1;
                    }
                    if (wi < inst_end) {
                        try result.append(alloc, words[wi]);
                        wi += 1;
                    }
                },
                'E' => {
                    // OpEntryPoint: copy string words, then remap interface IDs
                    while (wi < inst_end) {
                        const w = words[wi];
                        try result.append(alloc, w);
                        wi += 1;
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) {
                            break;
                        }
                    }
                    while (wi < inst_end) : (wi += 1) {
                        try result.append(alloc, remap(mapping, words[wi]));
                    }
                },
                else => {},
            }
        }
        pos = inst_end;
    }

    return result.toOwnedSlice(alloc);
}

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

        const info = getOpInfo(opcode) orelse { pos = inst_end; continue; };
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
                41, 42, 43, 44, 50 => true, // Constants
                61 => true, // Load
                65 => true, // AccessChain
                77, 79, 80, 81 => true, // Composite ops
                84 => true, // Transpose
                100, 103, 104, 105, 106, 107 => true, // Image queries
                109, 110, 111, 112, 114, 124 => true, // Conversions
                126, 127 => true, // Negate
                128...133, 135...138, 141, 142 => true, // Arithmetic
                144...148 => true, // Matrix/vector ops
                154...157 => true, // All/Any/IsNan/IsInf
                166...168, 170, 171 => true, // LogicalOr/And/Not/Equal/NotEqual
                169 => true, // Select
                173, 177 => true, // Comparisons
                180, 182, 184, 186 => true, // FOrd comparisons
                196, 198, 199, 200 => true, // Bit ops
                207...215 => true, // Derivatives
                12 => true, // ExtInst
                // Type instructions (result_only, no side effects)
                19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 32, 33 => true, // Types
                39 => true, // TypeForwardPointer
                4472, 5341, 4163 => true, // TypeRayQueryKHR, TypeAccelerationStructureKHR, TypeTensorARM
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
                const info = getOpInfo(opcode) orelse {
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
            const info2 = getOpInfo(opcode2) orelse { pos = ie2; continue; };
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
        current_words = new_words;
    }

    return current_words;
}
