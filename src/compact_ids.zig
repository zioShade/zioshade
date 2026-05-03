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
        143 => rt(2, "ii"),        // OpMatrixTimesScalar
        144...148 => rt(2, "ii"),  // OpVectorTimesMatrix..OpDot
        // --- Relational ---
        154...155 => rt(2, "i"),   // OpAll, OpAny
        156...157 => rt(2, "i"),   // OpIsNan, OpIsInf
        166...168 => rt(2, "ii"),  // OpLogicalOr, OpLogicalAnd, OpLogicalNot (168 is unary)
        169 => rt(2, "iii"),       // OpSelect
        170...171 => rt(2, "ii"),  // OpIEqual, OpINotEqual
        172 => rt(2, "ii"),        // OpUGreaterThan
        173 => rt(2, "ii"),        // OpSGreaterThan
        174 => rt(2, "ii"),        // OpUGreaterThanEqual
        175 => rt(2, "ii"),        // OpSGreaterThanEqual
        176 => rt(2, "ii"),        // OpULessThan
        177 => rt(2, "ii"),        // OpSLessThan
        178 => rt(2, "ii"),        // OpULessThanEqual
        179 => rt(2, "ii"),        // OpSLessThanEqual
        180 => rt(2, "ii"),        // OpFOrdEqual
        182 => rt(2, "ii"),        // OpFOrdNotEqual
        184 => rt(2, "ii"),        // OpFOrdLessThan
        186 => rt(2, "ii"),        // OpFOrdGreaterThan
        188 => rt(2, "ii"),        // OpFOrdLessThanEqual
        190 => rt(2, "ii"),        // OpFOrdGreaterThanEqual
        // --- Bit ---
        194 => rt(2, "ii"),        // OpShiftRightLogical
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
                143 => true, // OpMatrixTimesScalar
                144...148 => true, // Matrix/vector ops
                154...157 => true, // All/Any/IsNan/IsInf
                166...168, 170, 171 => true, // LogicalOr/And/Not/Equal/NotEqual
                169 => true, // Select
                172, 173, 174, 175, 176, 177, 178, 179 => true, // Integer comparisons
                180, 182, 184, 186, 188, 190 => true, // FOrd comparisons
                194, 196, 198, 199, 200 => true, // Shift + Bit ops
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
                    if (storage_class == 7) { // Function storage class
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
                            if (wc >= 5) {
                                const base = current_words[pos + 3];
                                if (base < current_bound and func_vars.isSet(base)) {
                                    loaded_vars.set(base);
                                }
                            }
                        },
                        37 => { // OpCopyMemory: dst=op1, src=op2
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
    {
        const fwd_bound = current_words[3];
        if (fwd_bound > 1) {
            // Build result_id -> position map for quick replacement
            // Also build a replacement map: old_id -> new_id
            var replacements = std.AutoHashMapUnmanaged(u32, u32){};
            defer replacements.deinit(alloc);

            // First pass: find forwarding opportunities
            // Track stores per block (cleared at OpLabel)
            var last_store = std.AutoHashMapUnmanaged(u32, u32){}; // ptr -> val
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
                    const info = getOpInfo(opcode) orelse {
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
                                while (wi + 1 < inst_end) {
                                    wi += 1;
                                    try fwd_result.append(alloc, current_words[wi]); // literal
                                    wi += 1;
                                    const w = current_words[wi];
                                    try fwd_result.append(alloc, replacements.get(w) orelse w);
                                }
                                if (wi < inst_end) {
                                    try fwd_result.append(alloc, current_words[wi]);
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

    return current_words;
}

/// Merge chained AccessChain instructions where the base is itself an AccessChain result
/// and the base AccessChain is only used once (by the current one).
pub fn mergeAccessChains(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Build result_id -> instruction position map for AccessChains
    const AC = struct { pos: u32, base_id: u32, indices_start: u32, indices_count: u32, result_id: u32 };
    var ac_map = std.AutoHashMapUnmanaged(u32, AC){}; // result_id -> AC info
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
    var ref_count = std.AutoHashMapUnmanaged(u32, u32){};
    defer ref_count.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        // Count references to AccessChain results (skip the definition itself)
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        const info = getOpInfo(opcode) orelse { pos += wc; continue; };
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
            const info = getOpInfo(opcode) orelse { pos += wc; continue; };
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
    var result = std.ArrayListUnmanaged(u32){};
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
            var index_groups = std.ArrayListUnmanaged(struct { start: u32, count: u32 }){};
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

/// Dead loop elimination: remove loops whose bodies have no observable side effects
/// and whose computed values are never used after the loop.
pub fn deadLoopElim(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Collect function-local variable IDs
    var func_vars = std.AutoHashMapUnmanaged(u32, void){};
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
    var loops = std.ArrayListUnmanaged(LI){};
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
                    if (!func_vars.contains(words[pos + 1])) has_side_effects = true;
                } else if (opcode == 37 or opcode == 234 or opcode == 235 or
                           (opcode >= 57 and opcode <= 60) or
                           (opcode >= 68 and opcode <= 76) or opcode == 99) {
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
                const info = getOpInfo(opcode) orelse { pos += wc; continue; };
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
                const info = getOpInfo(opcode) orelse { pos += wc; continue; };
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

        if (!value_escapes) dead_loops.set(li);
    }

    if (dead_loops.count() == 0) return words;

    // Filter inner loops contained within dead outer loops
    var dead_ranges = std.ArrayListUnmanaged(struct { header_label: u32, merge_label: u32, hdr_pos: u32, mrg_pos: u32 }){};
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

    var dead_header_labels = std.AutoHashMapUnmanaged(u32, u32){};
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
    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}
