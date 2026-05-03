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

pub fn getOpInfo(opcode: u16) ?OpInfo {
    // fixed: 0=none, 1=result_type, 2=result_type+result, 3=result_only
    return switch (opcode) {
        // --- Core ---
        1 => rt(2, ""),          // OpUndef: result_type, result
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
        245 => rt(2, "I"),          // OpPhi: result_type, result, (value, parent)...
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
                87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98 => true, // Image sampling (pure — safe to remove if result unused)
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
                            if (wc >= 5) {
                                const base = current_words[pos + 3];
                                if (base < current_bound and func_vars.isSet(base)) {
                                    loaded_vars.set(base);
                                    // Conservatively mark as stored too — AC result may be used for stores
                                    stored_vars.set(base);
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
                        54 => { // OpFunctionCall: args after func_id may be read/written
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
                var xb_total_stores = std.AutoHashMapUnmanaged(u32, u32){}; // var_id -> total store count
                defer xb_total_stores.deinit(alloc);
                var xb_entry_store_val = std.AutoHashMapUnmanaged(u32, u32){}; // var_id -> value (only if 1 entry store)
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
                        if (opcode == 37 and wc >= 3) {
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
                var xb_var_to_value = std.AutoHashMapUnmanaged(u32, u32){};
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
                    var xb_load_fwd = std.AutoHashMapUnmanaged(u32, u32){};
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
                            const info = getOpInfo(opcode) orelse {
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
                                    'W' => { while (wi + 1 < ie) { wi += 1; try xb_result.append(alloc, current_words[wi]); wi += 1; try xb_result.append(alloc, xb_load_fwd.get(current_words[wi]) orelse current_words[wi]); } if (wi < ie) { try xb_result.append(alloc, current_words[wi]); wi += 1; } },
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

/// Block merging: when block A ends with OpBranch %B and B has exactly one predecessor (A),
/// merge B into A by appending B's instructions (minus the label) to A.
pub fn mergeBlocks(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Pass 1: Build label -> position map and count predecessors
    var label_pos = std.AutoHashMapUnmanaged(u32, u32){}; // label_id -> pos of OpLabel
    defer label_pos.deinit(alloc);
    var predecessors = std.AutoHashMapUnmanaged(u32, u32){}; // label_id -> count
    defer predecessors.deinit(alloc);
    var branch_target = std.AutoHashMapUnmanaged(u32, u32){}; // label_id -> branch target (only for OpBranch)
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

        if (opcode == 252 and wc >= 2) { // OpSwitch
            const default = words[pos + 1];
            const ed = predecessors.getOrPutValue(alloc, default, 0) catch null;
            if (ed) |e| e.value_ptr.* += 1;
            var si: u32 = 2;
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

    // Collect loop merge and continue targets
    var loop_targets = std.DynamicBitSet.initEmpty(alloc, bound) catch return words;
    defer loop_targets.deinit();
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if (opcode == 246 and wc >= 3) { // OpLoopMerge
            if (words[pos + 1] < bound) loop_targets.set(words[pos + 1]); // merge
            if (words[pos + 2] < bound) loop_targets.set(words[pos + 2]); // continue
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
        if (loop_targets.isSet(to_label)) continue; // loop merge/continue target
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
            var lp2 = std.AutoHashMapUnmanaged(u32, u32){};
            defer lp2.deinit(alloc);
            var preds2 = std.AutoHashMapUnmanaged(u32, u32){};
            defer preds2.deinit(alloc);
            var bt2 = std.AutoHashMapUnmanaged(u32, u32){}; // from_label -> to_label
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
                pos += wc2;
            }

            // Find mergeable empty predecessors
            var empty_preds = std.AutoHashMapUnmanaged(u32, u32){}; // from_label -> to_label
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
                    const final_dce = deadCodeElim(alloc, r2.items) catch return r2.items;
                    if (final_dce.ptr != r2.items.ptr) alloc.free(r2.items);
                    return final_dce;
                } else {
                    r2.deinit(alloc);
                }
            }
        }
    }

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
    var replacements = std.AutoHashMapUnmanaged(u32, u32){};
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

        const info = getOpInfo(opcode) orelse {
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

/// Deduplicate struct types with identical member layouts.
/// Multiple OpTypeStruct with same member types → remap to first one, remove duplicates.
pub fn dedupStructTypes(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Collect struct types: map (member_type_0, member_type_1, ...) → first result_id
    // Use a simple approach: hash the member types, store in a HashMap
    var structs = std.AutoHashMapUnmanaged(u64, u32){}; // hash -> first_id
    defer structs.deinit(alloc);

    // Also build a replacement map for duplicate struct ids
    var replacements = std.AutoHashMapUnmanaged(u32, u32){}; // dup_id -> first_id
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
                if (members.len == first_members.len and std.mem.eql(u32, members, first_members)) {
                    // True duplicate — remap
                    try replacements.put(alloc, result_id, first_id);
                } else {
                    // Hash collision — store separately (use result_id to disambiguate)
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

        const info = getOpInfo(opcode) orelse {
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

/// Double negation elimination: FNegate(FNegate(x)) → x, SNegate(SNegate(x)) → x.
/// Also handles LogicalNot(LogicalNot(x)) → x and BitwiseNot(BitwiseNot(x)) → x.
pub fn eliminateDoubleNegate(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Collect negate instructions: map result_id -> (opcode, operand_id)
    // OpFNegate = 127, OpSNegate = 128, OpLogicalNot = 133, OpNot (bitwise) = 131
    var neg_ops = std.AutoHashMapUnmanaged(u32, struct { opcode: u16, operand: u32 }){};
    defer neg_ops.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        if ((opcode == 127 or opcode == 128 or opcode == 131 or opcode == 133) and wc == 4) {
            const result_id = words[pos + 2];
            const operand = words[pos + 3];
            try neg_ops.put(alloc, result_id, .{ .opcode = opcode, .operand = operand });
        }
        pos += wc;
    }

    // Find double negations: negate(negate(x)) → x
    var replacements = std.AutoHashMapUnmanaged(u32, u32){}; // result_id -> inner_operand
    defer replacements.deinit(alloc);

    var it = neg_ops.iterator();
    while (it.next()) |entry| {
        const outer_result = entry.key_ptr.*;
        const outer_opcode = entry.value_ptr.opcode;
        const inner_id = entry.value_ptr.operand;
        // Check if the inner is also a negate of the same type
        if (neg_ops.get(inner_id)) |inner| {
            if (inner.opcode == outer_opcode) {
                // double negation: outer_result = negate(negate(x)) → x
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
        if ((opcode == 127 or opcode == 128 or opcode == 131 or opcode == 133) and wc >= 4 and replacements.contains(words[pos + 2])) {
            pos = ie;
            continue;
        }

        const info = getOpInfo(opcode) orelse {
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
            if ((storage_class == 7 or storage_class == 3 or storage_class == 6) and result_id < bound) {
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
    var dead_stores = std.AutoHashMapUnmanaged(u32, void){}; // pos -> dead store
    defer dead_stores.deinit(alloc);

    // Track AC results derived from func-local vars
    var ac_from_func = std.AutoHashMapUnmanaged(u32, void){}; // ac_result_id -> void
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
    var last_store_pos = std.AutoHashMapUnmanaged(u32, u32){}; // ptr -> last store pos
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
    var replacements = std.AutoHashMapUnmanaged(u32, u32){};
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
                        if (float_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                    },
                    128 => { // OpIAdd
                        if (int_zero_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                        if (int_zero_ids.isSet(a)) try replacements.put(alloc, result_id, b);
                    },
                    132 => { // OpIMul
                        if (int_one_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                        if (int_one_ids.isSet(a)) try replacements.put(alloc, result_id, b);
                    },
                    133 => { // OpFMul
                        if (float_one_ids.isSet(b)) try replacements.put(alloc, result_id, a);
                        if (float_one_ids.isSet(a)) try replacements.put(alloc, result_id, b);
                    },
                    else => {},
                }
            }
        }
        pos += wc;
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

        // Skip eliminated instructions
        if (wc >= 3) {
            const result_id = words[pos + 2];
            if (result_id > 0 and result_id < bound and replacements.contains(result_id)) {
                pos = ie;
                continue;
            }
        }

        // Rewrite using getOpInfo for correct operand handling
        const info = getOpInfo(opcode) orelse {
            // No info — just copy, but still replace IDs in operands
            var ri: u32 = pos;
            while (ri < ie) : (ri += 1) {
                const w = words[ri];
                try result.append(alloc, replacements.get(w) orelse w);
            }
            pos = ie;
            continue;
        };

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
    var funcs = std.ArrayListUnmanaged(FuncInfo){};
    defer funcs.deinit(alloc);
    var param_slices = std.ArrayListUnmanaged([]const u32){};
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
            var param_ids = std.ArrayListUnmanaged(u32){};

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
    var inlineable = std.AutoHashMapUnmanaged(u32, *const FuncInfo){};
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
            var result_ids = std.AutoHashMapUnmanaged(u32, u32){};
            var bp: u32 = bs;
            while (bp < be) {
                const bh = w[bp]; const bwc: u32 = bh >> 16; const bop: u16 = @truncate(bh & 0xFFFF);
                if (bwc == 0) break;
                const info = getOpInfo(bop) orelse { bp += bwc; continue; };
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
                const info = getOpInfo(bop) orelse {
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
                                wi += 1; try out.append(allocator, w[wi]);
                                wi += 1; try out.append(allocator, repl.get(w[wi]) orelse w[wi]);
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
    result.appendSliceAssumeCapacity(words[0..4]);
    try result.append(alloc, bound);

    // Persistent substitution map: for non-void inlines where return value is
    // not a body-defined ID (e.g., a constant), replace call_result with return
    // value in all subsequent instructions.
    var sub_map = std.AutoHashMapUnmanaged(u32, u32){};
    defer sub_map.deinit(alloc);

    // Helper: apply sub_map to a single instruction and append to result
    const applySub = struct {
        fn run(allocator: std.mem.Allocator, w: []const u32, p: u32, _ie: u32, sm: std.AutoHashMapUnmanaged(u32, u32), out: *std.ArrayList(u32)) !void {
            _ = _ie;
            const bh = w[p]; const bwc: u32 = bh >> 16; const bop: u16 = @truncate(bh & 0xFFFF);
            const bie = p + bwc;
            const info = getOpInfo(bop) orelse {
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
                            wi += 1; try out.append(allocator, w[wi]);
                            wi += 1; try out.append(allocator, sm.get(w[wi]) orelse w[wi]);
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
                var repl = std.AutoHashMapUnmanaged(u32, u32){};
                errdefer repl.deinit(alloc);

                // Param -> arg
                const arg_start = pos + 4;
                for (fi.param_ids, 0..) |pid, i| {
                    if (arg_start + i < ie) try repl.put(alloc, pid, words[arg_start + i]);
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
                    // If body is non-empty and return value is body-defined, map it to call_result
                    // so the body instruction produces the call's result
                    if (fi.body_start < fi.body_end and fresh_map.count() > 0) {
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
        // Separate OpVariable instructions from everything else
        var var_insts = std.ArrayList(u32).initCapacity(alloc, 64) catch return words;
        var other_insts = std.ArrayList(u32).initCapacity(alloc, words.len - pos) catch { var_insts.deinit(alloc); return words; };
        var found_misplaced = false;

        while (pos < words.len) {
            const bh = words[pos];
            const bwc: u32 = bh >> 16;
            const bop: u16 = @truncate(bh & 0xFFFF);
            if (bwc == 0) break;
            const bie = pos + bwc;

            if (bop == 56) { // OpFunctionEnd
                // Emit: all vars, then all others, then OpFunctionEnd
                if (var_insts.items.len > 0) result.appendSliceAssumeCapacity(var_insts.items);
                if (other_insts.items.len > 0) result.appendSliceAssumeCapacity(other_insts.items);
                result.appendSliceAssumeCapacity(words[pos..bie]);
                pos = bie;
                break;
            }

            if (bop == 248) { // OpLabel — new block starts, flush buffers
                if (var_insts.items.len > 0) result.appendSliceAssumeCapacity(var_insts.items);
                if (other_insts.items.len > 0) result.appendSliceAssumeCapacity(other_insts.items);
                var_insts.clearRetainingCapacity();
                other_insts.clearRetainingCapacity();
                result.appendSliceAssumeCapacity(words[pos..bie]);
                pos = bie;
                continue;
            }

            if (bop == 59) { // OpVariable
                if (other_insts.items.len > 0) found_misplaced = true;
                var_insts.appendSliceAssumeCapacity(words[pos..bie]);
            } else {
                other_insts.appendSliceAssumeCapacity(words[pos..bie]);
            }
            pos = bie;
        }

        if (found_misplaced) any_moved = true;
        var_insts.deinit(alloc);
        other_insts.deinit(alloc);
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
    var load_to_var = std.AutoHashMapUnmanaged(u32, u32){};
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
            54 => { // OpFunctionCall: args may be read/written
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
    var load_type = std.AutoHashMapUnmanaged(u32, u32){};
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

    // Phase 2: Build substitution map for redundant loads
    // Track first load result per read-only var, per function
    var sub_map = std.AutoHashMapUnmanaged(u32, u32){}; // redundant_load_result -> first_load_result
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
            var first_loads = std.AutoHashMapUnmanaged(u32, u32){}; // var_id -> first_load_result
            defer first_loads.deinit(alloc);

            var fp = ie;
            while (fp < words.len) {
                const fh = words[fp];
                const fwc: u32 = fh >> 16;
                const fop: u16 = @truncate(fh & 0xFFFF);
                if (fwc == 0) break;
                const fie = fp + fwc;
                if (fie > words.len) break;

                if (fop == 56) break; // OpFunctionEnd

                if (fop == 61 and fwc >= 4) { // OpLoad
                    const result_id = words[fp + 2];
                    const ptr = words[fp + 3];
                    if (ptr < bound and readonly_vars.isSet(ptr)) {
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
        const info = getOpInfo(opcode) orelse {
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
                        wi += 1; result.append(alloc, words[wi]) catch return words;
                        wi += 1; result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
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
            var components = std.ArrayListUnmanaged(u32){};
            var ci: u32 = pos + 3;
            while (ci < ie) : (ci += 1) {
                components.append(alloc, words[ci]) catch return words;
            }
            construct_map.put(alloc, result_id, components) catch return words;
        }
        pos = ie;
    }

    if (construct_map.count() == 0) return words;

    // Phase 2: Find OpCompositeExtract that can be folded
    var sub_map = std.AutoHashMapUnmanaged(u32, u32){};
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
            if (construct_map.get(composite_id)) |components| {
                if (index < components.items.len) {
                    try sub_map.put(alloc, result_id, components.items[index]);
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

        // Skip folded extracts
        if (opcode == 81 and wc >= 5) {
            const result_id = words[pos + 2];
            if (sub_map.contains(result_id)) {
                pos = ie;
                continue;
            }
        }

        // Apply substitution
        const info = getOpInfo(opcode) orelse {
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
                        wi += 1; result.append(alloc, words[wi]) catch return words;
                        wi += 1; result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
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
    var sub_map = std.AutoHashMapUnmanaged(u32, u32){};
    defer sub_map.deinit(alloc);

    // Phase 1b: For each AccessChain, store its signature words so we can dedup
    // Per-block: track signatures and their first result IDs (must be same block for dominance)
    // Also track entry-block AccessChains for cross-block dedup (entry block dominates all)
    const SigEntry = struct { result_id: u32, sig_start: u32, sig_len: u32 };
    var block_sigs = std.ArrayListUnmanaged(SigEntry){}; // entries for current block
    defer block_sigs.deinit(alloc);
    var entry_block_sigs = std.ArrayListUnmanaged(SigEntry){}; // entries from function entry block
    defer entry_block_sigs.deinit(alloc);
    var all_sig_words = std.ArrayListUnmanaged(u32){}; // packed signature words
    defer all_sig_words.deinit(alloc);
    var is_entry_block = true; // track if we're in the function entry block

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
            is_entry_block = true;
        }
        if (opcode == 248) { // OpLabel — new block
            if (!is_entry_block) {
                block_sigs.clearRetainingCapacity();
            }
        }
        // Any non-Label instruction after first OpLabel ends entry block status
        if (opcode != 248 and opcode != 54 and opcode != 55 and opcode != 56) {
            is_entry_block = false;
        }

        if (opcode == 65 and wc >= 4) { // OpAccessChain
            const result_id = words[pos + 2]; // result
            const sig_type = words[pos + 1]; // result type
            const sig_base_and_indices = words[pos + 3 .. ie]; // base + indices
            const sig_len: u32 = 1 + @as(u32, @intCast(sig_base_and_indices.len));

            // Check for duplicate in current block first
            var found_dup = false;
            for (block_sigs.items) |entry| {
                if (entry.sig_len == sig_len) {
                    const existing_sig = all_sig_words.items[entry.sig_start .. entry.sig_start + sig_len];
                    if (existing_sig[0] == sig_type and std.mem.eql(u32, existing_sig[1..], sig_base_and_indices)) {
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
                        if (existing_sig[0] == sig_type and std.mem.eql(u32, existing_sig[1..], sig_base_and_indices)) {
                            try sub_map.put(alloc, result_id, entry.result_id);
                            found_dup = true;
                            break;
                        }
                    }
                }
            }
            if (!found_dup) {
                const sig_start: u32 = @intCast(all_sig_words.items.len);
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
            const sig_len: u32 = 1 + @as(u32, @intCast(sig_operands.len));

            var found_dup = false;
            for (block_sigs.items) |entry| {
                if (entry.sig_len == sig_len) {
                    const existing_sig = all_sig_words.items[entry.sig_start .. entry.sig_start + sig_len];
                    if (existing_sig[0] == sig_type and std.mem.eql(u32, existing_sig[1..], sig_operands)) {
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
                        if (existing_sig[0] == sig_type and std.mem.eql(u32, existing_sig[1..], sig_operands)) {
                            try sub_map.put(alloc, result_id, entry.result_id);
                            found_dup = true;
                            break;
                        }
                    }
                }
            }
            if (!found_dup) {
                const sig_start: u32 = @intCast(all_sig_words.items.len);
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
        if ((opcode == 65 and wc >= 4) or (opcode == 86 and wc >= 5)) {
            const result_id = words[pos + 2];
            if (sub_map.contains(result_id)) {
                pos = ie;
                continue;
            }
        }

        // Apply substitution to ID operands
        const info = getOpInfo(opcode) orelse {
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
                        wi += 1; result.append(alloc, words[wi]) catch return words;
                        wi += 1; result.append(alloc, sub_map.get(words[wi]) orelse words[wi]) catch return words;
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
