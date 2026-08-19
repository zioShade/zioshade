// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V binary → MSL (Metal Shading Language) cross-compiler backend.
//! Self-contained: includes its own parser, name resolver, and MSL emitter.

const compat = @import("compat.zig");
const std = @import("std");
const spirv = @import("spirv.zig");

const common = @import("spirv_cross_common.zig");
const compact_ids = @import("compact_ids.zig");
const Instruction = common.Instruction;
const ParsedModule = common.ParsedModule;
const DecorationEntry = struct { decoration: spirv.Decoration, extra: []const u32 };
const CbufferDecl = struct { name: []const u8, type_id: u32, binding: u32, descriptor_set: u32 = 0 };

// A loose (non-block) uniform gathered into the synthesized `_Globals` block
// (#417). The synthesized block itself is represented as a CbufferDecl named
// "_Globals" with type_id 0 (no backing SPIR-V struct), so it flows through the
// param/call/argument-buffer plumbing like any other uniform block; only its
// struct-member emission is special-cased.
const LooseUniform = struct { name: []const u8, type_id: u32 };
/// `is_depth` marks a comparison/shadow sampler (its OpTypeImage Depth operand
/// is 1, e.g. `sampler2DShadow`). Such a texture's MSL `.sample_compare` /
/// `.gather_compare` methods are members of `depth2d<float>`, NOT
/// `texture2d<float>` — see mslTextureType. Emitting `texture2d<float>` for one
/// yields MSL that does not compile.
/// `dim` is the SPIR-V `Dim` operand (word[3] of OpTypeImage): 0=1D, 1=2D,
/// 2=3D, 3=Cube, … `arrayed` is the `Arrayed` operand (word[5]): 1 for an
/// array texture (sampler2DArray, samplerCubeArray, …). Both feed mslTextureType
/// to build the correct `textureNd[_array]` / `depthNd[_array]` spelling, and
/// the sample-call layer split at the OpImageSample sites.
// `msl_type` is the full prebuilt MSL texture spelling incl. the `<component>`
// (e.g. `texture2d<int>`, `depthcube<float>`), populated in collectResources by
// `buildMslTextureType` and read at the emit sites. It is intentionally NOT
// defaulted: a construction site that forgets it should be a compile error, not
// a silent `texture2d<float>` for an int/cube/array sampler (#203).
const TextureDecl = struct { name: []const u8, binding: u32, descriptor_set: u32 = 0, is_depth: bool = false, dim: u32 = 1, arrayed: bool = false, msl_type: []const u8, var_id: u32 = 0, is_storage: bool = false };
const MemberKey = struct { struct_id: u32, member_index: u32 };
/// A stage input that becomes a `main0_in` field and is referenced in the body
/// as `in.<name>`. For fragment the field is `T name [[user(locnN)]]`; for
/// vertex it is `T name [[attribute(N)]]` (N = the Location decoration). The
/// `location` field carries N in both cases; only the attribute spelling
/// differs at emit time. Built-in inputs (gl_FragCoord etc.) are NOT collected
/// here — they keep their existing `[[position]]`/builtin path.
const StageInputDecl = struct { var_id: u32, name: []const u8, type_id: u32, location: u32, component: ?u32 = null, interp: []const u8 = "" };
/// A vertex stage output that becomes a `main0_out` field and is referenced in
/// the body as `out.<name>`. Two kinds:
///   - user varyings (`is_position == false`): `T name [[user(locnN)]]`,
///     emitted in ascending Location order.
///   - gl_Position (`is_position == true`): `float4 gl_Position [[position]]`,
///     emitted LAST (matching spirv-cross --msl). It is made a struct field so
///     a body `gl_Position = ...` store resolves to `out.gl_Position = ...`,
///     never a bare local.
///   - gl_PointSize (`is_point_size == true`): `float gl_PointSize [[point_size]]`,
///     emitted right after gl_Position (matching spirv-cross --msl).
///   - `from_block == true`: this decl was decomposed from a gl_PerVertex interface
///     Block (glslang/shaderc form), so `var_id` is the BLOCK var (shared across the
///     block's members) and body stores reach it via OpAccessChain, not a direct
///     var rename. The entry routes the block var to `out` once and skips these in
///     the per-var rename loop. (#471)
const StageOutputDecl = struct { var_id: u32, name: []const u8, type_id: u32, location: u32, is_position: bool, is_point_size: bool = false, from_block: bool = false };

/// #472: a FRAGMENT Output, classified into the Metal-representable kinds the
/// multi-field main0_out path emits. `color` carries the Location (-> [[color(N)]])
/// and an optional dual-source Index (-> `, index(M)`). The builtin kinds map to
/// their Metal attributes: frag_depth -> [[depth(...)]], sample_mask ->
/// [[sample_mask]], stencil_ref (FragStencilRefEXT 5014) -> [[stencil]]. The Metal
/// type of a builtin output differs from the SPIR-V pointee type in some cases
/// (gl_SampleMask is int[1] in SPIR-V but a scalar uint [[sample_mask]] in Metal),
/// so `msl_type` overrides `type_id` for those.
const FragOutputKind = enum { color, frag_depth, sample_mask, stencil_ref };
const FragOutput = struct {
    var_id: u32,
    name: []const u8,
    type_id: u32, // SPIR-V pointee type (used to derive the Metal type)
    kind: FragOutputKind,
    location: u32 = 0, // color outputs only
    index: ?u32 = null, // dual-source color only
};

// ---- Helpers ----

/// Format an OpSwitch case literal with the SELECTOR's signedness.
///
/// SPIR-V stores the literal as the selector's raw bit pattern, so for a signed
/// selector 0xFFFFFFFF means -1, not 4294967295. Metal rejects the wide literal
/// outright ("case value evaluates to 4294967295, which cannot be narrowed to
/// type 'int'"), and the C-family backends silently emit a case the selector can
/// never equal -- that arm just never runs. graphicsfuzz_082 and _026 both carry
/// such a case; neither reached this code until the #early-return-arm fix stopped
/// refusing them.
/// True when an emitted case body already ends in a statement that leaves the
/// switch, so a trailing `break;` after it would be unreachable.
///
/// Deliberately a check on the EMITTED TEXT rather than on the SPIR-V. The
/// static caseTerminatorTarget helper returns null for several distinct reasons
/// (label not found, next block reached, no Branch at all), so it cannot tell a
/// case that returns from a case whose first block ends in a BranchConditional.
/// The text answers exactly the question being asked, and it is the same
/// question tools/unreachable_scan.py asks.
fn caseBodyTerminates(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '\n');
    var last: []const u8 = "";
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len != 0) last = t;
    }
    if (std.mem.eql(u8, last, "break;") or std.mem.eql(u8, last, "continue;") or
        std.mem.eql(u8, last, "discard;")) return true;
    return std.mem.startsWith(u8, last, "return") and std.mem.endsWith(u8, last, ";");
}

fn switchCaseLiteral(m: *const ParsedModule, selector_id: u32, cv: u32) i64 {
    const tid = common.getTypeOf(m, selector_id) orelse return cv;
    const t = getDef(m, tid) orelse return cv;
    if (t.op == .TypeInt and t.words.len > 3 and t.words[3] != 0) {
        return @as(i32, @bitCast(cv));
    }
    return cv;
}

fn getDef(m: *const ParsedModule, id: u32) ?Instruction {
    if (id >= m.id_defs.len) return null;
    const i = m.id_defs[id] orelse return null;
    if (i >= m.instructions.len) return null;
    return m.instructions[i];
}

/// The value string for an operand id: its name, a bool literal, or the SSA
/// fallback `v{id}`. Mirrors the GLSL exprName; used to spell OpPhi incoming
/// values when materializing a selection-merge phi.
fn mslExprName(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), id: u32, alloc: std.mem.Allocator) []const u8 {
    if (names.get(id)) |n| return n;
    const def = getDef(m, id) orelse return std.fmt.allocPrint(alloc, "v{d}", .{id}) catch "0";
    if (def.op == .ConstantTrue) return "true";
    if (def.op == .ConstantFalse) return "false";
    if (def.op == .ConstantNull) {
        // OpConstantNull = the zero value for the type. spirv-opt -O produces
        // these for default/else values (e.g., out-of-bounds color = float3(0)).
        const tn = mslValueType(m, def.words[1], names, alloc) catch return "0";
        if (tn.len > 0 and tn[tn.len - 1] >= '0' and tn[tn.len - 1] <= '9') {
            // Vector/matrix (trailing digit): use constructor.
            return std.fmt.allocPrint(alloc, "{s}(0)", .{tn}) catch "0";
        }
        if (std.mem.eql(u8, tn, "float") or std.mem.eql(u8, tn, "half")) return "0.0";
        if (std.mem.eql(u8, tn, "bool")) return "false";
        return "0";
    }
    return std.fmt.allocPrint(alloc, "v{d}", .{id}) catch "0";
}

/// Whether block `target` is reachable from `cur` by following terminators without
/// entering `stop` (the selection merge). Used to attribute an OpPhi predecessor to
/// the true vs false side of a selection — a copy of the GLSL backend's helper, so
/// nested selections attribute correctly. See spirv_to_glsl.labelReaches.
fn mslLabelReaches(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), cur: u32, target: u32, stop: u32, seen: *std.AutoHashMap(u32, void)) bool {
    if (cur == stop) return false;
    if (cur == target) return true;
    if (seen.contains(cur)) return false;
    seen.put(cur, {}) catch return false;
    const bi = label_map.get(cur) orelse return false;
    var j = bi + 1;
    while (j < m.instructions.len) : (j += 1) {
        const inst = m.instructions[j];
        switch (inst.op) {
            .Branch => return if (inst.words.len >= 2) mslLabelReaches(m, label_map, inst.words[1], target, stop, seen) else false,
            .BranchConditional => {
                if (inst.words.len < 4) return false;
                if (mslLabelReaches(m, label_map, inst.words[2], target, stop, seen)) return true;
                return mslLabelReaches(m, label_map, inst.words[3], target, stop, seen);
            },
            .Switch => {
                if (inst.words.len >= 3 and mslLabelReaches(m, label_map, inst.words[2], target, stop, seen)) return true;
                var k: usize = 3;
                while (k + 1 < inst.words.len) : (k += 2) {
                    if (mslLabelReaches(m, label_map, inst.words[k + 1], target, stop, seen)) return true;
                }
                return false;
            },
            .Return, .ReturnValue, .Kill, .Unreachable, .Label => return false,
            else => {},
        }
    }
    return false;
}

/// True if phi predecessor `pred1` lies in the TRUE region of a selection.
fn mslPhiPred1InTrueRegion(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), tl: u32, mval: u32, pred1: u32, alloc: std.mem.Allocator) bool {
    var seen = std.AutoHashMap(u32, void).init(alloc);
    defer seen.deinit();
    return mslLabelReaches(m, label_map, tl, pred1, mval, &seen);
}

const MslMergePhi = struct { result_id: u32, type_id: u32, vals: [2]u32, preds: [2]u32 };

/// Collect the OpPhi instructions at selection-merge block `mval` (a selection
/// merge's phis appear at the top of the merge block). Two-incoming phis only
/// (the if/else shape); more-incoming phis are left to other handling.
fn collectMergePhis(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), mval: u32, list: *std.ArrayList(MslMergePhi), alloc: std.mem.Allocator) void {
    const midx = label_map.get(mval) orelse return;
    var pj: usize = midx + 1;
    while (pj < m.instructions.len) : (pj += 1) {
        const minst = m.instructions[pj];
        if (minst.op != .Phi) break;
        if (minst.words.len >= 7) {
            list.append(alloc, .{ .result_id = minst.words[2], .type_id = minst.words[1], .vals = .{ minst.words[3], minst.words[5] }, .preds = .{ minst.words[4], minst.words[6] } }) catch {};
        }
    }
}
// #477: SWITCH-merge phi materialization (N incoming). Mirrors the HLSL backend —
// declare a `_phi` var per phi before the switch, assign the matching incoming at each
// case body's end. Separate from the 2-incoming if/else machinery.
fn collectSwitchMergePhis(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), ml: u32, list: *std.ArrayList(Instruction), alloc: std.mem.Allocator) void {
    const midx = label_map.get(ml) orelse return;
    var pj: usize = midx + 1;
    while (pj < m.instructions.len) : (pj += 1) {
        const minst = m.instructions[pj];
        if (minst.op != .Phi) break;
        list.append(alloc, minst) catch {};
    }
}
// True if `lbl` is a case target (default or a case literal target) of switch_inst.
fn isSwitchCaseTarget(switch_inst: Instruction, lbl: u32) bool {
    if (switch_inst.words.len >= 3 and switch_inst.words[2] == lbl) return true; // default
    var i: usize = 3;
    while (i + 1 < switch_inst.words.len) : (i += 2) {
        if (switch_inst.words[i + 1] == lbl) return true;
    }
    return false;
}
// True if any case body OpBranches to another case target (fallthrough). Used to
// detect spirv-opt's fallthrough lowering (cross-case phi chain) that needs the
// chain-materialization emission path.
fn switchIsFallthrough(m: *const ParsedModule, switch_inst: Instruction, merge_lbl: u32, label_map: *const std.AutoHashMap(u32, usize)) bool {
    var wi: usize = 3;
    while (wi + 1 < switch_inst.words.len) : (wi += 2) {
        const target = switch_inst.words[wi + 1];
        if (target == merge_lbl) continue;
        const tidx = label_map.get(target) orelse continue;
        var ri: usize = tidx + 1;
        while (ri < m.instructions.len) : (ri += 1) {
            const rinst = m.instructions[ri];
            if (rinst.op == .Label or rinst.op == .FunctionEnd or rinst.op == .BranchConditional) break;
            if (rinst.op == .Branch and rinst.words.len > 1) {
                const bt = rinst.words[1];
                if (bt != merge_lbl and bt != target and isSwitchCaseTarget(switch_inst, bt)) return true;
                break;
            }
        }
    }
    return false;
}
// Collect cross-case chain phis for a fallthrough switch: for each case-target
// block, the OpPhis at its top are the chain phis (each = phi(initial, prev-case-
// value)). Record the block, the entry incoming (from a non-case pred), and the
// OpSwitch literal (for the entry-init `if(sel==literal) chain_phi=initial`).
fn collectSwitchChainPhis(m: *const ParsedModule, switch_inst: Instruction, merge_lbl: u32, label_map: *const std.AutoHashMap(u32, usize), list: *std.ArrayList(ChainPhiEntry), alloc: std.mem.Allocator) void {
    var wi: usize = 3;
    while (wi + 1 < switch_inst.words.len) : (wi += 2) {
        const literal = switch_inst.words[wi];
        const target = switch_inst.words[wi + 1];
        if (target == merge_lbl) continue;
        const bidx = label_map.get(target) orelse continue;
        var pi: usize = bidx + 1;
        while (pi < m.instructions.len) : (pi += 1) {
            const pinst = m.instructions[pi];
            if (pinst.op != .Phi or pinst.words.len < 5) break;
            // Find the entry incoming (pred is NOT a case target).
            var entry_value: u32 = 0;
            var found_entry = false;
            var pp: usize = 3;
            while (pp + 1 < pinst.words.len) : (pp += 2) {
                if (!isSwitchCaseTarget(switch_inst, pinst.words[pp + 1])) {
                    entry_value = pinst.words[pp];
                    found_entry = true;
                    break;
                }
            }
            if (found_entry) {
                list.append(alloc, .{ .phi = pinst, .block = target, .entry_value = entry_value, .literal = @intCast(literal) }) catch {};
            }
        }
    }
}
/// Name of the materialized variable for phi result `rid`.
///
/// Derived from the IMMUTABLE result id, never by suffixing whatever `names` happens
/// to hold. `names` maps ids to EXPRESSIONS, not identifiers, and passes rewrite it
/// between the declaration and the use, so suffixing it produced three distinct
/// failures: a declaration and a use that disagree (`v57_phi` declared, `v246_phi`
/// referenced), repeated suffixing across finalize paths (`v56_phi_phi_phi_phi`), and
/// aliasing to a folded constant (`_GLF_color = ((float4)0)_phi;`). This is the same
/// defect #559 fixed in the HLSL backend; the MSL copy was never ported.
///
/// One exception: an id the #413 pre-scan hoisted above a loop is deliberately NOT
/// renamed to `_phi`, so it keeps its hoisted name.
fn mslPhiVarName(names: *std.AutoHashMap(u32, []const u8), rid: u32, alloc: std.mem.Allocator) []const u8 {
    if (g_hoisted_ids) |h| {
        if (h.contains(rid)) {
            // Duplicated, not returned by reference: callers may `fetchPut` this back
            // into `names` and free the displaced value, which would otherwise be this
            // exact slice.
            const cur = names.get(rid) orelse "pv";
            return alloc.dupe(u8, cur) catch cur;
        }
    }
    return std.fmt.allocPrint(alloc, "v{d}_phi", .{rid}) catch "pv_phi";
}
/// True if THIS site should print the declaration of phi `rid`'s variable.
///
/// A phi between a loop header and its merge is walked by the loop pre-scan of every
/// ENCLOSING loop as well as by whichever construct actually owns it, so the same
/// variable reaches several declaration sites. Before mslPhiVarName the repeated
/// declarations each got a different name (`v47_phi`, `v47_phi_phi`, ...) and so did
/// not collide -- at the cost of the decl/use mismatch that motivated the rename.
/// With one stable name they collide, so the first (outermost, therefore widest
/// scope, therefore covering every assignment and read) declaration wins and later
/// sites emit assignments only.
///
/// Module-scoped rather than function-scoped on purpose: phi result ids are SSA ids,
/// unique across the module, so a phi belongs to exactly one function.
fn mslPhiDeclare(rid: u32) bool {
    const dp = g_declared_phis orelse return true;
    if (dp.contains(rid)) return false;
    dp.put(rid, {}) catch {};
    return true;
}
fn emitSwitchPhiDecls(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), phis: []const Instruction, w: anytype, alloc: std.mem.Allocator) !void {
    for (phis) |phi| {
        // #switch-merge-phi-hoist-shadow: an id the #413 pre-scan hoisted above the
        // enclosing loop is ALREADY declared there, under this same name (mslPhiVarName
        // keeps the hoisted name). Declaring it again here shadows the hoisted variable:
        // the case copies below then write the per-iteration shadow while the top-of-loop
        // carry copy (`vN = <this phi>;`) reads the never-written hoisted original, so
        // the carried value is undef on every iteration (graphicsfuzz_022: the BST
        // search counter stayed 0 and the shader rendered the wrong constant color).
        // Skip; the hoisted declaration sits above the loop and covers this scope.
        if (g_hoisted_ids) |h| if (h.contains(phi.words[2])) continue;
        if (!mslPhiDeclare(phi.words[2])) continue;
        const t = try mslValueType(m, phi.words[1], names, alloc);
        const vn = mslPhiVarName(names, phi.words[2], alloc);
        try w.print("    {s} {s};\n", .{ t, vn });
    }
}
fn emitSwitchPhiCaseCopy(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), phis: []const Instruction, case_label: u32, w: anytype, alloc: std.mem.Allocator) !void {
    for (phis) |phi| {
        const vn = mslPhiVarName(names, phi.words[2], alloc);
        var pi: usize = 3;
        while (pi + 1 < phi.words.len) : (pi += 2) {
            if (phi.words[pi + 1] == case_label) {
                try w.print("        {s} = {s};\n", .{ vn, mslExprName(m, names, phi.words[pi], alloc) });
                break;
            }
        }
    }
}
fn finalizeSwitchPhis(names: *std.AutoHashMap(u32, []const u8), phis: []const Instruction, alloc: std.mem.Allocator) void {
    for (phis) |phi| {
        const pn = mslPhiVarName(names, phi.words[2], alloc);
        if (names.fetchPut(phi.words[2], pn) catch null) |old| alloc.free(old.value);
        if (g_materialized_phis) |mp| mp.put(phi.words[2], {}) catch {};
    }
}
// #loop-merge-phi: a phi at a loop's MERGE block selects between the values
// arriving from each exit path (the normal exit + every break). Aliasing it to a
// single incoming (the generic OpPhi handler's old behavior) silently drops the
// break path's distinct value -> wrong render whenever a loop reads the variable
// after a break (while_complex: `sum` read after `if (sum > 0.8) break;`,
// maxdiff=63). Mirrors the switch-merge phi machinery + spirv-cross's `_82`:
// collect DIVERGENT merge phis, declare a distinct var, assign the per-exit-path
// incoming. A non-diverging phi (all incomings equal) aliases fine and is skipped.
fn collectLoopMergePhis(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), merge_lbl: u32, list: *std.ArrayList(Instruction), alloc: std.mem.Allocator) void {
    const midx = label_map.get(merge_lbl) orelse return;
    var pj: usize = midx + 1;
    while (pj < m.instructions.len) : (pj += 1) {
        const minst = m.instructions[pj];
        if (minst.op != .Phi) break;
        if (minst.words.len < 7) continue; // need >=2 (value,pred) pairs to diverge
        var first_val: u32 = 0;
        var diverges = false;
        var pi: usize = 3;
        while (pi + 1 < minst.words.len) : (pi += 2) {
            if (pi == 3) {
                first_val = minst.words[pi];
            } else if (minst.words[pi] != first_val) {
                diverges = true;
                break;
            }
        }
        if (diverges) list.append(alloc, minst) catch {};
    }
}
// The UNIFIED merge-phi copy: assign one materialized merge phi (loop OR switch
// OR selection) its incoming value for predecessor `pred_lbl`. One mechanism for
// every merge kind (Design's unified-subsystem constraint) — used by the
// loop-merge-phi carry-on-break AND the switch-merge-phi early-return copy. If
// `pred_lbl` is not among the phi's predecessors, emit nothing (a loop's
// top-of-loop fallback covers unhandled paths; for switches every branch-to-merge
// pred is explicit).
fn emitMergePhiCopyForPred(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), phi: Instruction, pred_lbl: u32, indent: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    var pi: usize = 3;
    while (pi + 1 < phi.words.len) : (pi += 2) {
        if (phi.words[pi + 1] == pred_lbl) {
            const vn = names.get(phi.words[2]) orelse "pv";
            try w.print("{s}{s} = {s};\n", .{ indent, vn, mslExprName(m, names, phi.words[pi], alloc) });
            return;
        }
    }
}
// The block label containing the instruction at index `idx` (nearest preceding
// OpLabel). Used to resolve the predecessor for a merge-phi copy at a
// branch-to-merge: the branch's own block, independent of how emitBlock advanced
// its instruction cursor (it skips block Labels via i = lm.get(merge) + loop
// increment, so a tracked "current label" would be stale).
fn blockLabelOf(m: *const ParsedModule, idx: usize) u32 {
    var j: usize = idx;
    while (true) {
        if (m.instructions[j].op == .Label and m.instructions[j].words.len > 1) return m.instructions[j].words[1];
        if (j == 0) return 0;
        j -= 1;
    }
}
fn getMemberName(m: *const ParsedModule, struct_id: u32, member_idx: u32, buf: *[32]u8) []const u8 {
    return common.commonGetMemberName(m.instructions, struct_id, member_idx, buf, "_m");
}
fn swizzleChar(i: u32) []const u8 {
    return switch (i) {
        0 => ".x",
        1 => ".y",
        2 => ".z",
        3 => ".w",
        else => ".x",
    };
}
fn parseLitStr(alloc: std.mem.Allocator, words: []const u32) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, words.len * 4);
    for (words) |word| {
        const bytes: [4]u8 = @bitCast(word);
        for (bytes) |c| {
            if (c == 0) break;
            buf.appendAssumeCapacity(c);
        }
    }
    return buf.toOwnedSlice(alloc);
}
fn sanitizeName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, name.len);
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => buf.appendAssumeCapacity(c),
            else => buf.appendAssumeCapacity('_'),
        }
    }
    return buf.toOwnedSlice(alloc);
}
fn isUniformVar(m: *const ParsedModule, id: u32) bool {
    const inst = getDef(m, id) orelse return false;
    if (inst.op == .Variable and inst.words.len >= 4) {
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        // PushConstant blocks are emitted as UBO-style `constant T& name_1`
        // buffers (#483), so member access qualifies through the same `_1` path.
        if (sc == .PushConstant) return true;
        if (sc == .Uniform) {
            // An old-style SSBO (Uniform + BufferBlock on the pointee struct) is
            // emitted as `device T& name` (NOT the `constant T& name_1` UBO form).
            // Flagging it here would make the body emitter apply the `_1` UBO
            // qualifier to a `device` reference -> undeclared identifier. Modern
            // SSBOs (StorageBuffer class) already return false above.
            if (resolvePointee(m, id)) |ptid| {
                if (hasBufferBlockDec(m, ptid)) return false;
            }
            return true;
        }
    }
    return false;
}

/// True if struct type `type_id` carries a BufferBlock decoration (old-style SSBO).
/// Linear scan -- isUniformVar / writeAccessExpr have no `decs` map in scope.
fn hasBufferBlockDec(m: *const ParsedModule, type_id: u32) bool {
    const bb = @intFromEnum(spirv.Decoration.buffer_block);
    for (m.instructions) |inst| {
        if (inst.op == .Decorate and inst.words.len >= 3 and
            inst.words[1] == type_id and inst.words[2] == bb) return true;
    }
    return false;
}

/// True when the resource's image type is a 2D depth/comparison image (the
/// OpTypeImage `Depth` operand is 1 AND `Dim` is 2D), e.g. a `sampler2DShadow`.
/// `pointee` is the type behind the UniformConstant pointer: either an
/// OpTypeSampledImage (wrapping the OpTypeImage) or an OpTypeImage directly.
/// OpTypeImage layout: `[op, result_id, sampled_type, DIM, DEPTH, arrayed, ms,
/// sampled, format]` — so `words[3]` is Dim and `words[4]` is Depth.
///
/// Only 2D is gated on purpose: this whole backend hardcodes 2D textures, so a
/// non-2D depth sampler (samplerCubeShadow → depthcube, sampler2DArrayShadow →
/// depth2d_array, etc.) must NOT be promoted to `depth2d` — that would swap one
/// non-compiling type for another. zioshade marks ALL shadow samplers with
/// Depth=1 regardless of dimension, so the Dim check is what keeps the depth2d
/// promotion scoped to the case it actually models. Non-2D textures (shadow or
/// not) are a separate, backend-wide gap.
fn imageTypeIsDepth(m: *const ParsedModule, pointee: Instruction) bool {
    var img = pointee;
    if (img.op == .TypeSampledImage and img.words.len > 2) {
        img = getDef(m, img.words[2]) orelse return false;
    }
    if (img.op != .TypeImage or img.words.len <= 4) return false;
    const dim = img.words[3]; // SPIR-V Dim: 1 == 2D, 3 == Cube
    const depth = img.words[4]; // 0 = non-depth, 1 = depth, 2 = no indication
    // MSL has `depth2d`/`depthcube` (+ _array) but no `depth1d`/`depth3d`, so
    // only 2D and Cube depth/shadow samplers map to the depth family (#208);
    // a 1D shadow keeps the texture family (no MSL depth type exists for it).
    if (depth == 1 and (dim == 1 or dim == 3)) return true;
    // #493: depth-from-usage -- a regular texture (Depth=0) used in a depth
    // OpSampledImage (e.g. GL_EXT samplerless `sampler2DShadow(t, s)`) must be
    // depth2d for sample_compare. g_depth_tex_types holds such image type-ids.
    if (g_depth_tex_types) |dt| {
        if ((dim == 1 or dim == 3) and dt.contains(img.words[1])) return true;
    }
    return false;
}

/// True if the shader accesses gl_FragCoord component z (2) or w (3). MSL threads
/// gl_FragCoord.xy into the impl as a `float2 _fragCoord` (the common shadertoy
/// case); a shader that reads .z (depth) or .w needs the FULL `float4` threaded
/// instead, or the body's `.z`/`.w` access exceeds the float2 (Metal rejects it).
/// Detected via an OpAccessChain into the var with a constant index >= 2, or a
/// CompositeExtract with component >= 2 from a load of the var.
/// True iff instruction `u` references id `vid` in a genuine ID-OPERAND position
/// (per the opcode's operand mask — literal/string words never match; a blind
/// word scan false-positives on e.g. OpTypeVector's component count or embedded
/// name strings). Mirrors the walker in compact_ids_passes' deadLoopElim Phase 3.
fn opReferencesValue(u: Instruction, vid: u32) bool {
    const info = compact_ids.getOpInfo(@intFromEnum(u.op)) orelse return false;
    var wi: usize = 1;
    switch (info.fixed) {
        1 => wi = 2, // result_type
        2 => wi = 3, // result_type + result
        3 => wi = 2, // result only
        else => wi = 1,
    }
    // Fixed-position ids first (the result type / result are NOT references).
    for (info.ops) |ch| {
        if (wi >= u.words.len) break;
        switch (ch) {
            'i' => {
                if (u.words[wi] == vid) return true;
                wi += 1;
            },
            'I' => {
                while (wi < u.words.len) : (wi += 1) {
                    if (u.words[wi] == vid) return true;
                }
            },
            'M' => {
                if (wi < u.words.len) wi += 1; // literal
                while (wi < u.words.len) : (wi += 1) {
                    if (u.words[wi] == vid) return true;
                }
            },
            'W' => {
                while (wi + 1 < u.words.len) {
                    wi += 1;
                    if (u.words[wi] == vid) return true;
                    wi += 1;
                }
                if (wi < u.words.len) wi += 1;
            },
            'E' => {
                while (wi < u.words.len) {
                    const w = u.words[wi];
                    wi += 1;
                    if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) break;
                }
                while (wi < u.words.len) : (wi += 1) {
                    if (u.words[wi] == vid) return true;
                }
            },
            else => wi += 1, // literal / string / type-operand position: skip
        }
    }
    return false;
}

fn fragCoordNeedsFullVec(m: *const ParsedModule, fcvid: u32) bool {
    // Direct .z/.w indexing into the var.
    for (m.instructions) |inst| {
        if (inst.op == .AccessChain and inst.words.len >= 5 and inst.words[3] == fcvid) {
            const idxd = getDef(m, inst.words[4]);
            if (idxd != null and idxd.?.op == .Constant and idxd.?.words.len > 3 and idxd.?.words[3] >= 2) return true;
        }
    }
    // Whole-vec loads: a full load aliases `_fragCoord` VERBATIM, so with only
    // float2 threaded ANY whole-vector use emits a float2 into a float4 context
    // (invalid Metal: stored whole, arithmetic, call arg, copy, extract >= 2,
    // shuffle reaching >= 2). INVERTED CONTRACT (review of the first attempt,
    // which whitelisted store/shuffle/extract and missed the rest): thread
    // float4 UNLESS every use of every full load is PROVABLY xy-only. The
    // frontend's canonical lowering (full load + VectorShuffle 0 1) stays
    // float2; ambiguous shapes move to the safe float4.
    for (m.instructions, 0..) |ld, li| {
        if (ld.op != .Load or ld.words.len < 4 or ld.words[3] != fcvid) continue;
        const loadid = ld.words[2];
        var used = false;
        var provably_xy = true;
        for (m.instructions, 0..) |u, ui| {
            if (ui == li) continue;
            // Does u reference the load in a real ID-operand position?
            if (!opReferencesValue(u, loadid)) continue;
            used = true;
            if (u.op == .CompositeExtract and u.words.len >= 5 and u.words[3] == loadid and u.words[4] < 2) continue;
            if (u.op == .VectorShuffle and u.words.len >= 5 and (u.words[3] == loadid or u.words[4] == loadid)) {
                // Selectors < n1 index Vector1, >= n1 index Vector2 (n1 =
                // Vector1's component count — NOT hardcoded 4; spirv-opt emits
                // shuffles with a non-vec4 Vector1). Every selector that maps to
                // a component OF THE LOAD must map to < 2.
                const v1def = getDef(m, u.words[3]);
                const n1: u32 = if (v1def != null and v1def.?.words.len >= 2) typeRank(m, v1def.?.words[1]) else 4;
                var wi: usize = 4;
                var all_xy = true;
                while (wi + 1 < u.words.len) : (wi += 1) {
                    const sel = u.words[wi + 1];
                    if (sel == 0xFFFFFFFF) continue;
                    const comp: i64 = blk: {
                        if (sel < n1) {
                            if (u.words[3] == loadid) break :blk @as(i64, @intCast(sel));
                            break :blk -1; // indexes the OTHER vector
                        } else {
                            if (u.words[4] == loadid and sel >= n1) break :blk @as(i64, @intCast(sel)) - @as(i64, @intCast(n1));
                            break :blk -1;
                        }
                    };
                    if (comp >= 2) {
                        all_xy = false;
                        break;
                    }
                }
                if (all_xy) continue;
            }
            provably_xy = false;
        }
        if (!used or !provably_xy) return true;
    }
    return false;
}

/// The Metal unsigned coordinate type matching coordinate VALUE `id`'s width.
/// Metal's `texture.read()` takes `uint`/`uintN`, never a SIGNED coordinate — GLSL
/// texelFetch/imageLoad hand it an `int`/`ivecN` coord, so the read must cast it or
/// Metal rejects the call ("no matching member function for call to 'read'"). The
/// cast width MATCHES the coordinate's own component count (only the signedness
/// changes), so a coord that is already the right width/type is never resized.
fn mslReadCoordCast(m: *const ParsedModule, id: u32) []const u8 {
    const def = getDef(m, id) orelse return "uint2";
    if (def.words.len < 2) return "uint2";
    return switch (typeRank(m, def.words[1])) {
        1 => "uint",
        3 => "uint3",
        4 => "uint4",
        else => "uint2",
    };
}

/// Component count of a result type id: 1 for a scalar, else the OpTypeVector
/// size. OpTypeVector layout: `[op, result_id, component_type, count]`.
fn typeRank(m: *const ParsedModule, type_id: u32) u32 {
    const ti = getDef(m, type_id) orelse return 1;
    if (ti.op == .TypeVector and ti.words.len > 3) return ti.words[3];
    return 1;
}

/// The perspective-divide component for a projective coordinate VALUE: the
/// coordinate's LAST component. textureProj(sampler2D, vec3) divides .xy by .z;
/// the vec4 form divides by .w. Hardcoding `.w` produced an out-of-range swizzle
/// (float3 has no .w) for the vec3 form = invalid MSL. Resolves the coord value's
/// result type (`words[1]`) and reads its component count. (#170)
fn projDivisorSwizzle(m: *const ParsedModule, coord_value_id: u32) []const u8 {
    const vdef = getDef(m, coord_value_id) orelse return ".w";
    if (vdef.words.len < 2) return ".w";
    return if (typeRank(m, vdef.words[1]) == 3) ".z" else ".w";
}

/// True when the image VALUE `id` resolves to an Arrayed OpTypeImage (2D array,
/// cube array, 2DMS array). Used to choose `get_array_size()` (layer count) vs
/// `get_depth()` (volume depth) for the third component of an image-size query.
/// Resolves the value's result type (`words[1]`) and unwraps an
/// OpTypeSampledImage. OpTypeImage layout:
/// `[op, result_id, sampled_type, DIM, DEPTH, ARRAYED, ms, sampled, format]`.
fn imageValueIsArrayed(m: *const ParsedModule, image_value_id: u32) bool {
    const vdef = getDef(m, image_value_id) orelse return false;
    if (vdef.words.len < 2) return false;
    var tinst = getDef(m, vdef.words[1]) orelse return false;
    if (tinst.op == .TypeSampledImage and tinst.words.len > 2) {
        tinst = getDef(m, tinst.words[2]) orelse return false;
    }
    if (tinst.op != .TypeImage or tinst.words.len < 6) return false;
    return tinst.words[5] == 1;
}

/// SPIR-V `Dim` operand of the image behind a sampled-image VALUE `id`
/// (0=1D, 1=2D, 2=3D, 3=Cube). Mirrors `imageValueIsArrayed`: resolves the
/// value's result type and unwraps an OpTypeSampledImage. Returns 1 (2D) when it
/// cannot be resolved, matching the backend's 2D default.
fn imageValueDim(m: *const ParsedModule, image_value_id: u32) u32 {
    const vdef = getDef(m, image_value_id) orelse return 1;
    if (vdef.words.len < 2) return 1;
    var tinst = getDef(m, vdef.words[1]) orelse return 1;
    if (tinst.op == .TypeSampledImage and tinst.words.len > 2) {
        tinst = getDef(m, tinst.words[2]) orelse return 1;
    }
    if (tinst.op != .TypeImage or tinst.words.len < 4) return 1;
    return tinst.words[3];
}

/// SPATIAL coord swizzle (".x"/".xy"/".xyz") for a NON-ARRAYED OpImageSampleDref*
/// coord operand, by sampler Dim. A glslang producer packs the dref INTO the coord
/// (vec3 for a 2D shadow), so passing the raw coord to MSL `.sample_compare` (which
/// wants the spatial rank -- float2 for depth2d) is a type mismatch Metal rejects.
/// The swizzle takes the leading spatial components; a scalar coord (1D shadow as a
/// bare float) takes none. Arrayed textures are handled separately
/// (mslArrayedSampleArgs). (#170)
fn mslDrefCoordSwizzle(m: *const ParsedModule, sampled_image_id: u32, coord_id: u32) []const u8 {
    if (getDef(m, coord_id)) |cdef| {
        if (cdef.words.len >= 2) {
            if (getDef(m, cdef.words[1])) |t| {
                if (t.op == .TypeFloat) return ""; // scalar coord (1D shadow)
            }
        }
    }
    return switch (imageValueDim(m, sampled_image_id)) {
        0 => ".x", // 1D
        3 => ".xyz", // Cube
        else => ".xy", // 2D (and default)
    };
}

/// True if an image VALUE (OpLoad result) is multisampled — the OpTypeImage MS
/// flag (word[6]). Mirrors imageValueDim's resolution (OpLoad -> its type, unwrapping
/// OpTypeSampledImage). Used to honest-error MS subpass reads (SubpassData + MS),
/// which need texture2d_ms + per-sample-read modeling this backend defers.
fn imageValueIsMultisampled(m: *const ParsedModule, image_value_id: u32) bool {
    const vdef = getDef(m, image_value_id) orelse return false;
    if (vdef.words.len < 2) return false;
    var tinst = getDef(m, vdef.words[1]) orelse return false;
    if (tinst.op == .TypeSampledImage and tinst.words.len > 2) {
        tinst = getDef(m, tinst.words[2]) orelse return false;
    }
    if (tinst.op != .TypeImage or tinst.words.len < 7) return false;
    return tinst.words[6] != 0; // MS flag (OpTypeImage: ..., Dim, Depth, Arrayed, MS, ...)
}

/// For an ARRAYED sampled-image VALUE, MSL passes the array layer as a SEPARATE
/// argument after the (dimension-sliced) coordinate. Given the SSA coordinate
/// name and the image dim, returns `"<coord>.xy, uint(rint(<coord>.z))"` (2D
/// array), `"<coord>.xyz, uint(rint(<coord>.w))"` (cube array), or
/// `"<coord>.x, uint(rint(<coord>.y))"` (1D array) — matching spirv-cross --msl.
/// The Dref (depth-compare) component is supplied separately by each
/// `OpImageSampleDref*` call site from the SPIR-V Dref operand, not here.
fn mslArrayedSampleArgs(alloc: std.mem.Allocator, coord: []const u8, dim: u32) ![]const u8 {
    return switch (dim) {
        3 => try std.fmt.allocPrint(alloc, "{s}.xyz, uint(rint({s}.w))", .{ coord, coord }),
        0 => try std.fmt.allocPrint(alloc, "{s}.x, uint(rint({s}.y))", .{ coord, coord }),
        // 2D (and any other) array layout: xy + layer in z.
        else => try std.fmt.allocPrint(alloc, "{s}.xy, uint(rint({s}.z))", .{ coord, coord }),
    };
}

/// Index of the ConstOffset (image-operand bit 0x8) value word for an
/// OpImageSampleDref* instruction. Dref occupies words[5] and the image-operands
/// mask is words[6], so operand values start at words[7]; ConstOffset follows
/// Bias(1)/Lod(1)/Grad(2) in ascending bit order. Returns null when ConstOffset
/// is absent or its word is missing. (#170)
fn drefConstOffsetIdx(words: []const u32) ?usize {
    if (words.len <= 6) return null;
    const mask = words[6];
    if (mask & 0x8 == 0) return null;
    var off: usize = 7;
    if (mask & 0x1 != 0) off += 1; // Bias
    if (mask & 0x2 != 0) off += 1; // Lod
    if (mask & 0x4 != 0) off += 2; // Grad
    if (off >= words.len) return null;
    return off;
}

/// Render a ConstOffset image operand (an OpConstantComposite of int constants)
/// INLINE as `intN(c0, c1, ...)` for an MSL `.sample(...)` trailing offset arg
/// (spirv-cross: `tex.sample(samp, uv, int2(1,2))`). Returns "" if `offset_id`
/// is not a renderable constant composite. Mirrors writeHlslConstOffset.
fn mslConstOffset(m: *const ParsedModule, alloc: std.mem.Allocator, offset_id: u32) []const u8 {
    const cc = getDef(m, offset_id) orelse return "";
    if (cc.op != .ConstantComposite or cc.words.len < 4) return "";
    const n = cc.words.len - 3;
    var buf = std.ArrayList(u8).initCapacity(alloc, 24) catch return "";
    buf.print(alloc, "int{d}(", .{n}) catch return "";
    for (cc.words[3..], 0..) |cid, i| {
        if (i > 0) buf.appendSlice(alloc, ", ") catch return "";
        if (getDef(m, cid)) |c| {
            if (c.op == .Constant and c.words.len > 3) {
                const v: i32 = @bitCast(c.words[3]);
                buf.print(alloc, "{d}", .{v}) catch return "";
                continue;
            }
        }
        buf.appendSlice(alloc, "0") catch return "";
    }
    buf.appendSlice(alloc, ")") catch return "";
    return buf.toOwnedSlice(alloc) catch "";
}

/// Integer-coordinate analogue of `mslArrayedSampleArgs` for `texture.read`
/// (OpImageFetch). `texelFetch` carries an already-integer coordinate, so the
/// spatial components are wrapped in `uintN(...)` and the array layer is split
/// into a separate `uint(...)` arg — matching spirv-cross --msl:
///   2D array → `"uint2(<coord>.xy), uint(<coord>.z)"`
///   1D array → `"uint(<coord>.x), uint(<coord>.y)"`
/// (Cube has no `texelFetch`; the 2D layout is the fallback.)
fn mslArrayedFetchArgs(alloc: std.mem.Allocator, coord: []const u8, dim: u32) ![]const u8 {
    return switch (dim) {
        0 => try std.fmt.allocPrint(alloc, "uint({s}.x), uint({s}.y)", .{ coord, coord }),
        // 2D (and any other) array layout: xy + layer in z.
        else => try std.fmt.allocPrint(alloc, "uint2({s}.xy), uint({s}.z)", .{ coord, coord }),
    };
}

/// The `component::<swizzle>` token spirv-cross uses for an OpImageGather
/// component operand. The operand is an OpConstant integer in 0..3; resolve its
/// literal (OpConstant layout `[op, result_type, result_id, value…]`) and map
/// 0→x, 1→y, 2→z, 3→w. Falls back to `component::x` when it cannot be resolved.
fn mslGatherComponent(m: *const ParsedModule, component_id: u32) []const u8 {
    const cdef = getDef(m, component_id) orelse return "component::x";
    if (cdef.op != .Constant or cdef.words.len < 4) return "component::x";
    return switch (cdef.words[3]) {
        1 => "component::y",
        2 => "component::z",
        3 => "component::w",
        else => "component::x",
    };
}

/// MSL texture type for a sampled texture parameter, built from the SPIR-V
/// `Dim` + `Arrayed` operands. Comparison/shadow samplers use the `depthNd…`
/// family (the home of `.sample_compare`/`.gather_compare`); everything else
/// uses `textureNd…`. The `Arrayed` operand appends an `_array` suffix
/// (sampler2DArray → texture2d_array<float>, samplerCubeArray →
/// texturecube_array<float>). Without it, every array sampler degraded to the
/// non-array 2D type (#187).
///
/// Dim spelling: 0=1d, 1=2d, 2=3d, 3=cube. Rect/Buffer/SubpassData and any
/// unmodelled dim fall back to `2d`, matching this backend's prior 2D-only
/// hardcode (those paths are separate, pre-existing gaps).
///
/// `depth*` is only produced for the 2D and Cube depth dims that map to real MSL
/// depth types (`depth2d`, `depth2d_array`, `depthcube`, `depthcube_array`); a
/// non-2D/Cube depth sampler keeps the texture family rather than inventing a
/// non-existent type (consistent with the prior 2D-scoped depth promotion).
/// The MSL texture family spelling WITHOUT the `<component>` suffix
/// (`texture2d_array`, `depthcube`, …). The component is appended by
/// `buildMslTextureType` so int/uint samplers get `<int>`/`<uint>` (#203).
fn mslTextureFamily(is_depth: bool, dim: u32, arrayed: bool, ms: bool) []const u8 {
    // Multisampled: Metal only has MS 2D (+ 2D-array) families. sampler2DMS /
    // isampler2DMS map here; get_num_samples() / read(coord, sample) are valid on
    // texture2d_ms but NOT on a plain texture2d (silent-wrong: sampler-ms-query).
    if (ms and dim == 1) {
        if (is_depth) return if (arrayed) "depth2d_ms_array" else "depth2d_ms";
        return if (arrayed) "texture2d_ms_array" else "texture2d_ms";
    }
    if (is_depth) {
        return switch (dim) {
            1 => if (arrayed) "depth2d_array" else "depth2d",
            3 => if (arrayed) "depthcube_array" else "depthcube",
            // Non-2D/Cube depth has no plain MSL depth type; fall back to the
            // texture family (pre-existing gap, kept stable).
            0 => if (arrayed) "texture1d_array" else "texture1d",
            2 => "texture3d",
            else => if (arrayed) "texture2d_array" else "texture2d",
        };
    }
    return switch (dim) {
        0 => if (arrayed) "texture1d_array" else "texture1d",
        2 => "texture3d", // 3D textures are never arrayed.
        3 => if (arrayed) "texturecube_array" else "texturecube",
        5 => "texture_buffer", // Dim=Buffer: samplerBuffer/imageBuffer. texture2d
        // makes .read(uint) ambiguous (vs uint2); texture_buffer is the 1D buffer
        // family whose .read(uint) is unambiguous.
        // 1 (2D) and any unmodelled dim → 2D family.
        else => if (arrayed) "texture2d_array" else "texture2d",
    };
}

/// Build the full MSL texture type (`texture2d_array<int>`, `depth2d<float>`, …)
/// from the SPIR-V `Dim`/`Arrayed`/sampled-type. The `component` is `float`,
/// `int`, or `uint` (decoded from the OpTypeImage sampled type); DEPTH textures
/// always use `float` (their `.sample_compare` is float-only). Returns an
/// arena-allocated string; falls back to a `<float>` literal on OOM.
fn buildMslTextureType(alloc: std.mem.Allocator, is_depth: bool, dim: u32, arrayed: bool, ms: bool, component: []const u8, access_suffix: []const u8) []const u8 {
    const fam = mslTextureFamily(is_depth, dim, arrayed, ms);
    const comp = if (is_depth) "float" else component;
    return std.fmt.allocPrint(alloc, "{s}<{s}{s}>", .{ fam, comp, access_suffix }) catch (if (arrayed) "texture2d_array<float>" else "texture2d<float>");
}

/// The MSL `<component>` spelling for a sampled texture, read from the
/// OpTypeImage sampled-type operand (word[2]): float → `float`, signed int →
/// `int`, unsigned int → `uint`. Defaults to `float` (#203).
fn mslSampledComponent(m: *const ParsedModule, img: Instruction) []const u8 {
    if (img.op != .TypeImage or img.words.len < 3) return "float";
    const st = getDef(m, img.words[2]) orelse return "float";
    return switch (st.op) {
        .TypeInt => if (st.words.len > 3 and st.words[3] == 0) "uint" else "int",
        else => "float",
    };
}

/// For an image VARIABLE id that is the target of an image atomic, return the MSL
/// atomic scalar ("uint"/"int") iff it is a 2D, non-arrayed, INTEGER storage image —
/// the only shape this backend emulates via the spvImage2DAtomicCoord buffer-backed
/// scheme. Returns null for anything else (1D/3D/cube, arrayed, float component) so
/// the caller can honest-error instead of mis-emitting. OpTypeImage operand layout:
/// [op, result, sampled_type(2), Dim(3), Depth(4), Arrayed(5), MS(6), Sampled(7), Format(8)].
fn mslAtomicImageScalar(m: *const ParsedModule, image_var_id: u32) ?[]const u8 {
    const v = getDef(m, image_var_id) orelse return null;
    if (v.op != .Variable or v.words.len < 2) return null;
    const ptr = getDef(m, v.words[1]) orelse return null;
    if (ptr.op != .TypePointer or ptr.words.len < 4) return null;
    const img = getDef(m, ptr.words[3]) orelse return null;
    if (img.op != .TypeImage or img.words.len < 6) return null;
    if (img.words[3] != 1) return null; // Dim: 1 == 2D
    if (img.words[5] != 0) return null; // Arrayed: must be 0
    const comp = mslSampledComponent(m, img);
    if (std.mem.eql(u8, comp, "uint")) return "uint";
    if (std.mem.eql(u8, comp, "int")) return "int";
    return null; // float → atomic_float is Metal 3.0+; out of scope
}

fn resolvePointee(m: *const ParsedModule, id: u32) ?u32 {
    const inst = getDef(m, id) orelse return null;
    switch (inst.op) {
        // OpFunctionParameter shares OpVariable's word layout (words[1] = pointer
        // result type). A struct pointer param (`thread Particle&`) was otherwise
        // unresolved, so its member accesses emitted a numeric index (v[1]) instead
        // of `.member`. (Mirrors the GLSL backend fix.)
        .Variable, .FunctionParameter => {
            const pt = getDef(m, inst.words[1]) orelse return null;
            if (pt.op == .TypePointer and pt.words.len > 3) return pt.words[3];
            return null;
        },
        .AccessChain => {
            var cur = resolvePointee(m, inst.words[3]);
            for (inst.words[4..]) |idx_id| {
                const idx_def = getDef(m, idx_id);
                if (cur) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur = tinst.words[2];
                        } else if (tinst.op == .TypeStruct) {
                            if (idx_def) |d| {
                                if (d.op == .Constant and d.words.len > 3) {
                                    const v = d.words[3];
                                    if (v + 2 < tinst.words.len) {
                                        cur = tinst.words[v + 2];
                                    } else cur = null;
                                }
                            }
                        } else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) {
                            cur = tinst.words[2];
                        } else {
                            cur = null;
                        }
                    } else {
                        cur = null;
                    }
                } else {
                    cur = null;
                }
            }
            return cur;
        },
        else => return null,
    }
}

/// NOTE: unlike `writeAccessExpr`, this alloc-based builder does NOT apply the
/// row_major `transpose(...)` correction — it builds a plain pointer expression.
/// It backs pointer/store contexts; matrix READS go through `writeAccessExpr`.
fn buildAccessExpr(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator) ![]const u8 {
    var base_buf: [96]u8 = undefined;
    var base_name: []const u8 = names.get(base_id) orelse "base";
    // #478: a flattened interface-block Input member. The struct-typed block var
    // has no MSL declaration; its first (constant) member index selects a
    // flattened `in.<block>_<member>` stage-in field. Rewrite the base and consume
    // that index; remaining indices (sub-vector swizzle, nested access) apply to
    // the member type as usual.
    var start: usize = 0;
    var cur_type_init: ?u32 = resolvePointee(m, base_id);
    // #500 recursive flatten: a flattened Input struct var -- consume ALL leading
    // constant struct-member indices down to the leaf field `in.<var>_<m0>_...`.
    if (mslConsumeFlatInputIndices(alloc, m, base_id, indices)) |r| {
        if (r.consumed > 0) {
            base_name = std.fmt.bufPrint(&base_buf, "in.{s}", .{r.name}) catch base_name;
            start = r.consumed;
            cur_type_init = r.term_type;
        }
    }
    const eff_indices = indices[start..];
    if (eff_indices.len == 0) return try alloc.dupe(u8, base_name);
    // Use a stack buffer to avoid heap allocation for typical access chains
    var writer = compat.StackBufWriter(512).init();
    writer.writeAll(base_name);
    var cur_type: ?u32 = cur_type_init;
    for (eff_indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: {
                    const ti = getDef(m, tid);
                    break :blk ti != null and ti.?.op == .TypeVector;
                } else false;
                if (is_vector) {
                    writer.writeAll(swizzleChar(val));
                } else {
                    // Use member name for structs, [index] for arrays
                    var used_name = false;
                    if (cur_type) |tid| {
                        const ti = getDef(m, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = getMemberName(m, tid, val, &mname_buf);
                                writer.print(".{s}", .{mname});
                                used_name = true;
                            }
                        }
                    }
                    if (!used_name) writer.print("[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur_type = tinst.words[2];
                        } else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) {
                            cur_type = tinst.words[val + 2];
                        }
                        // TypeRuntimeArray's element type is words[2], same as TypeArray.
                        // Omitting it dropped cur_type to null after a runtime-array
                        // index, so a following struct-member index emitted `[0]`
                        // instead of `.m` (e.g. SSBO `data[i].m` -> `data[i][0]`,
                        // silent-wrong). Advancing to the element keeps member names.
                        else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix or tinst.op == .TypeRuntimeArray) {
                            cur_type = tinst.words[2];
                        } else {
                            cur_type = null;
                        }
                    }
                }
            } else {
                writer.print("[{s}]", .{names.get(index_id) orelse "i"});
            }
        } else {
            writer.print("[{s}]", .{names.get(index_id) orelse "i"});
        }
    }
    if (!writer.overflowed()) {
        return try alloc.dupe(u8, writer.written());
    }
    // Fallback to heap for long chains
    var buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, base_name);
    cur_type = cur_type_init;
    for (eff_indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: {
                    const ti = getDef(m, tid);
                    break :blk ti != null and ti.?.op == .TypeVector;
                } else false;
                if (is_vector) {
                    try buf.appendSlice(alloc, swizzleChar(val));
                } else {
                    // Use member name for structs, [index] for arrays
                    var used_name = false;
                    if (cur_type) |tid| {
                        const ti = getDef(m, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = getMemberName(m, tid, val, &mname_buf);
                                try buf.print(alloc, ".{s}", .{mname});
                                used_name = true;
                            }
                        }
                    }
                    if (!used_name) try buf.print(alloc, "[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur_type = tinst.words[2];
                        } else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) {
                            cur_type = tinst.words[val + 2];
                        }
                        // TypeRuntimeArray's element type is words[2], same as TypeArray.
                        // Omitting it dropped cur_type to null after a runtime-array
                        // index, so a following struct-member index emitted `[0]`
                        // instead of `.m` (e.g. SSBO `data[i].m` -> `data[i][0]`,
                        // silent-wrong). Advancing to the element keeps member names.
                        else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix or tinst.op == .TypeRuntimeArray) {
                            cur_type = tinst.words[2];
                        } else {
                            cur_type = null;
                        }
                    }
                }
            } else {
                try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
            }
        } else {
            try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn writeResolvePointer(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, read_context: bool, w: anytype) !void {
    const inst = getDef(m, ptr_id) orelse {
        try w.writeAll(names.get(ptr_id) orelse "var");
        return;
    };
    if (inst.op == .AccessChain) {
        try writeAccessExpr(m, names, inst.words[3], inst.words[4..], read_context, w);
        return;
    }
    try w.writeAll(names.get(ptr_id) orelse "var");
}

/// Look up the SPIR-V `ArrayStride` decoration (bytes between consecutive
/// elements) on an array type id, scanning OpDecorate directly. Returns null if
/// absent. Mirrors memberMatrixStride but for the array-type decoration.
fn arrayStrideOf(m: *const ParsedModule, array_type_id: u32) ?u32 {
    for (m.instructions) |inst| {
        if (inst.op == .Decorate and inst.words.len >= 4 and inst.words[1] == array_type_id) {
            const dec: spirv.Decoration = @enumFromInt(inst.words[2]);
            if (dec == .array_stride) return inst.words[3];
        }
    }
    return null;
}

/// Resolve a type that is a matrix, or a (possibly nested) array of matrices,
/// down to the underlying matrix type id; null if it is not ultimately a matrix.
/// The `row_major` decoration sits on the struct MEMBER even when that member is
/// an array, so this is how we recover the matrix the member holds.
fn arrayMatrixElement(m: *const ParsedModule, type_id: u32) ?u32 {
    var tid = type_id;
    while (true) {
        const ti = getDef(m, tid) orelse return null;
        switch (ti.op) {
            .TypeArray, .TypeRuntimeArray => tid = ti.words[2],
            .TypeMatrix => return tid,
            else => return null,
        }
    }
}

/// A row-major matrix reached while walking an access chain. `boundary` is the
/// index position after which `cur_type` becomes the matrix (the struct-member
/// index for a direct matrix, or the array-element index for a matrix array);
/// `matrix_tid` is the matrix type id. Trailing indices (>`boundary`) index into
/// the logical matrix and are emitted by `writeMatrixTail`.
const RowMajorAccess = struct { boundary: usize, matrix_tid: u32 };

/// If `indices` reaches a `row_major` SQUARE matrix (a direct member or a matrix
/// array element), return where it sits in the chain. A `row_major` matrix is
/// stored column-major in MSL but holds the TRANSPOSE of the logical matrix, so
/// a read must wrap it in `transpose(...)`. Non-square row-major matrices also
/// need swapped member DIMENSIONS and are rejected up front by
/// `checkUnsupportedRowMajor`; only square ones reach here.
fn findRowMajorMatrix(m: *const ParsedModule, base_id: u32, indices: []const u32) ?RowMajorAccess {
    var cur_type: ?u32 = resolvePointee(m, base_id);
    var target: ?u32 = null; // square row-major matrix we are descending toward
    for (indices, 0..) |index_id, i| {
        const tid = cur_type orelse return null;
        const ti = getDef(m, tid) orelse return null;
        if (ti.op == .TypeStruct) {
            const def = getDef(m, index_id) orelse return null;
            if (def.op != .Constant or def.words.len <= 3) return null;
            const val = def.words[3];
            if (val + 2 >= ti.words.len) return null;
            const member_tid = ti.words[val + 2];
            // A row-major member that is (an array of) a SQUARE matrix: remember
            // the matrix type so we transpose once the chain reaches it.
            if (memberIsRowMajor(m, tid, val)) {
                if (arrayMatrixElement(m, member_tid)) |mtid| {
                    if (!matrixIsNonSquare(m, mtid)) target = mtid;
                }
            }
            cur_type = member_tid;
        } else if (ti.op == .TypeVector or ti.op == .TypeArray or ti.op == .TypeMatrix) {
            cur_type = ti.words[2];
        } else {
            return null;
        }
        if (target) |mt| {
            if (cur_type == mt) return .{ .boundary = i, .matrix_tid = mt };
        }
    }
    return null;
}

/// When a std140 UBO array element is widened to a *wider* 4-component MSL type
/// (e.g. `float arr[N]` stored as `float4 arr[N]` so the natural stride hits
/// 16), an `arr[i]` index yields the wide type while the GLSL element is
/// narrower. Return the trailing swizzle (".x"/".xy") that narrows the widened
/// element back to its component count — matching spirv-cross's `u.arr[0].x`.
/// Returns null when no narrowing applies: not an array, no ArrayStride, stride
/// already natural (std430 tight packing), or the element is a matrix/struct
/// (handled elsewhere). Crucially, this MUST mirror mslWidenedElementType, which
/// only widens 1- and 2-component elements to a 4-wide type; a 3-component
/// element stays `float3` (already 16-byte aligned) and a 4-component element
/// stays `float4`, so BOTH index cleanly with NO swizzle — appending `.xyz` to
/// a `float3` would diverge from the oracle even though it compiles.
fn widenedArrayElementSwizzle(m: *const ParsedModule, array_type_id: u32) ?[]const u8 {
    const arr = getDef(m, array_type_id) orelse return null;
    if (arr.op != .TypeArray and arr.op != .TypeRuntimeArray) return null;
    const elem_id = arr.words[2];
    const stride = arrayStrideOf(m, array_type_id) orelse return null;
    const nat = typeNatSize(m, elem_id);
    if (nat == 0 or stride <= nat) return null; // not widened (tight packing)
    const elem = getDef(m, elem_id) orelse return null;
    const comp_count: u32 = switch (elem.op) {
        .TypeFloat, .TypeInt => 1,
        .TypeVector => elem.words[3],
        else => return null, // matrices/structs: not a scalar-narrowing case
    };
    // Only 1- and 2-component elements are widened to a wider 4-wide MSL type by
    // mslWidenedElementType, so only those need narrowing. A 3-component element
    // stays float3 and a 4-component element stays float4 — both indexed bare.
    return switch (comp_count) {
        1 => ".x",
        2 => ".xy",
        else => null, // 3- or 4-wide element: not widened, no narrowing needed
    };
}

/// Emit the access-chain indices that come AFTER a (transposed) row-major
/// matrix: a matrix-column index becomes `[col]` on the transposed value, and a
/// vector-element index becomes a `.xyzw` swizzle — both valid MSL.
fn writeMatrixTail(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), matrix_tid: u32, indices: []const u32, w: anytype) !void {
    var cur_type: ?u32 = matrix_tid;
    for (indices) |index_id| {
        const def = getDef(m, index_id);
        const is_const = if (def) |d| (d.op == .Constant and d.words.len > 3) else false;
        if (!is_const) {
            try w.print("[{s}]", .{names.get(index_id) orelse "i"});
            continue;
        }
        const val = def.?.words[3];
        const ti = if (cur_type) |t| getDef(m, t) else null;
        if (ti) |t| {
            if (t.op == .TypeVector) {
                try w.writeAll(swizzleChar(val));
                cur_type = t.words[2];
            } else {
                try w.print("[{d}]", .{val});
                cur_type = if (t.op == .TypeMatrix or t.op == .TypeArray) t.words[2] else null;
            }
        } else {
            try w.print("[{d}]", .{val});
            cur_type = null;
        }
    }
}

/// Build an access-chain expression. On a READ that traverses a row-major
/// matrix member, the matrix sub-expression is wrapped in `transpose(...)` so
/// the column-major MSL storage is read as the logical (row-major) matrix —
/// matching the spirv-cross --msl oracle, which emits transposed access for a
/// `row_major` matrix. Writes (`read_context == false`) keep the plain form,
/// since you cannot assign through `transpose(...)`.
fn writeAccessExpr(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, read_context: bool, w: anytype) !void {
    if (read_context) {
        if (findRowMajorMatrix(m, base_id, indices)) |hit| {
            try w.writeAll("transpose(");
            try writeAccessExprPlain(m, names, base_id, indices[0 .. hit.boundary + 1], w);
            try w.writeAll(")");
            try writeMatrixTail(m, names, hit.matrix_tid, indices[hit.boundary + 1 ..], w);
            return;
        }
    }
    try writeAccessExprPlain(m, names, base_id, indices, w);
}

fn writeAccessExprPlain(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, w: anytype) !void {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) {
        try w.writeAll(base_name);
        return;
    }
    // #481: a scalar-ized Input builtin (gl_SampleMaskIn) — Metal's [[sample_mask]]
    // is a scalar, so drop the GLSL `[0]` array index and emit the bare name.
    if (g_scalar_builtin_vars) |sb| {
        if (sb.contains(base_id)) {
            try w.writeAll(base_name);
            return;
        }
    }
    // #478: a flattened interface-block Input member. The struct-typed block var
    // has no MSL declaration; its first (constant) member index selects the
    // flattened `in.<block>_<member>` stage-in field. Emit that and consume the
    // index; remaining indices apply to the member type.
    var eff_indices = indices;
    var block_handled = false;
    var block_member_type: ?u32 = null;
    if (g_block_flat) |bf| {
        if (bf.get(blockFlatKey(base_id, 0)) != null) { // flattened Input struct var
            // #500 recursive flatten: consume ALL leading constant struct-member
            // indices to the leaf field `in.<var>_<m0>_...` (stack buffer; sanitize
            // is a no-op for non-keyword leaf names, which covers the corpus).
            var nbuf: [160]u8 = undefined;
            const vname = bf.get(blockFlatKey(base_id, FLAT_VAR_NAME_MEMBER)) orelse names.get(base_id) orelse "vin";
            var nlen: usize = @min(vname.len, nbuf.len);
            @memcpy(nbuf[0..nlen], vname[0..nlen]);
            var cur_t: ?u32 = resolvePointee(m, base_id);
            var consumed: usize = 0;
            var overflow = false;
            for (indices) |index_id| {
                const idef = getDef(m, index_id) orelse break;
                if (idef.op != .Constant or idef.words.len <= 3) break;
                const val = idef.words[3];
                const ct = cur_t orelse break;
                const tdef = getDef(m, ct) orelse break;
                if (tdef.op != .TypeStruct or val + 2 >= tdef.words.len) break;
                var mnb: [32]u8 = undefined;
                const mname = getMemberName(m, ct, val, &mnb);
                if (nlen + 1 + mname.len > nbuf.len) {
                    overflow = true;
                    break;
                }
                nbuf[nlen] = '_';
                nlen += 1;
                @memcpy(nbuf[nlen..][0..mname.len], mname);
                nlen += mname.len;
                cur_t = tdef.words[val + 2];
                consumed += 1;
            }
            if (!overflow and consumed > 0) {
                try w.print("in.{s}", .{nbuf[0..nlen]});
                block_handled = true;
                eff_indices = indices[consumed..];
                block_member_type = cur_t;
                if (eff_indices.len == 0) return;
            }
        }
    }
    const base_is_cb = if (block_handled) false else isUniformVar(m, base_id);
    const cb_prefix = if (base_is_cb) names.get(base_id) orelse "Globals" else "";
    if (!base_is_cb and !block_handled) try w.writeAll(base_name);
    var cur_type: ?u32 = if (block_handled) block_member_type else resolvePointee(m, base_id);
    var first_member = true;
    for (eff_indices, 0..) |index_id, ix| {
        const is_last = ix + 1 == eff_indices.len;
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: {
                    const ti = getDef(m, tid);
                    break :blk ti != null and ti.?.op == .TypeVector;
                } else false;
                if (is_vector) {
                    try w.writeAll(swizzleChar(val));
                } else if (base_is_cb and first_member) {
                    // Use member name for structs, _mN fallback for others
                    if (cur_type) |tid| {
                        const ti = getDef(m, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = getMemberName(m, tid, val, &mname_buf);
                                try w.print("{s}_1.{s}", .{ cb_prefix, mname });
                            } else {
                                try w.print("{s}_1._m{d}", .{ cb_prefix, val });
                            }
                        } else {
                            try w.print("{s}_1._m{d}", .{ cb_prefix, val });
                        }
                    } else {
                        try w.print("{s}_1._m{d}", .{ cb_prefix, val });
                    }
                    first_member = false;
                } else if (base_is_cb) {
                    // Use member name for structs, [index] for arrays (with a
                    // trailing swizzle to narrow std140-widened elements, e.g.
                    // `arr[0].x`), _mN otherwise.
                    if (cur_type) |tid| {
                        const ti = getDef(m, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = getMemberName(m, tid, val, &mname_buf);
                                try w.print(".{s}", .{mname});
                            } else if (tinst.op == .TypeArray or tinst.op == .TypeRuntimeArray) {
                                try w.print("[{d}]", .{val});
                                // std140 rounds each array element up to 16 bytes,
                                // so a narrow element (float/vecN/int) is stored as
                                // a 4-wide MSL type. When this index is terminal,
                                // narrow back to the element width — matching
                                // spirv-cross's `u.arr[0].x`. A following component
                                // index narrows on its own, so only do this last.
                                if (is_last) {
                                    if (widenedArrayElementSwizzle(m, tid)) |sw| try w.writeAll(sw);
                                }
                            } else {
                                try w.print("._m{d}", .{val});
                            }
                        } else {
                            try w.print("._m{d}", .{val});
                        }
                    } else {
                        try w.print("._m{d}", .{val});
                    }
                } else {
                    // Non-cb: use member name for structs
                    if (cur_type) |tid| {
                        const ti = getDef(m, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = getMemberName(m, tid, val, &mname_buf);
                                try w.print(".{s}", .{mname});
                            } else {
                                try w.print("[{d}]", .{val});
                            }
                        } else {
                            try w.print("[{d}]", .{val});
                        }
                    } else {
                        try w.print("[{d}]", .{val});
                    }
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur_type = tinst.words[2];
                        } else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) {
                            cur_type = tinst.words[val + 2];
                        }
                        // TypeRuntimeArray's element type is words[2], same as TypeArray.
                        // Omitting it dropped cur_type to null after a runtime-array
                        // index, so a following struct-member index emitted `[0]`
                        // instead of `.m` (e.g. SSBO `data[i].m` -> `data[i][0]`,
                        // silent-wrong). Advancing to the element keeps member names.
                        else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix or tinst.op == .TypeRuntimeArray) {
                            cur_type = tinst.words[2];
                        } else {
                            cur_type = null;
                        }
                    }
                }
            } else {
                try w.print("[{s}]", .{names.get(index_id) orelse "i"});
                advanceArrayElem(m, &cur_type);
            }
        } else {
            try w.print("[{s}]", .{names.get(index_id) orelse "i"});
            advanceArrayElem(m, &cur_type);
        }
    }
}

/// Advance `cur_type` past a NON-constant (variable) access-chain index. A
/// variable index only ever indexes an array/runtime-array/matrix/vector (a
/// struct member index is always a constant), so the element type is `words[2]`
/// regardless of the index value. Without this, `cur_type` froze on the array
/// type and a following struct-member index emitted `[0]` instead of `.m`.
fn advanceArrayElem(m: *const ParsedModule, cur_type: *?u32) void {
    if (cur_type.*) |tid| {
        if (getDef(m, tid)) |tinst| {
            cur_type.* = switch (tinst.op) {
                .TypeVector, .TypeArray, .TypeMatrix, .TypeRuntimeArray => tinst.words[2],
                else => null,
            };
        }
    }
}

fn resolvePointer(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(m, ptr_id) orelse {
        const n = names.get(ptr_id) orelse "var";
        return try alloc.dupe(u8, n);
    };
    if (inst.op == .AccessChain) return try buildAccessExpr(m, names, inst.words[3], inst.words[4..], alloc);
    const n = names.get(ptr_id) orelse "var";
    return try alloc.dupe(u8, n);
}

/// MSL column-major matrix type for a UBO/SSBO matrix member, matching
/// spirv-cross --msl. The SPIR-V `MatrixStride` decoration is the column stride
/// in bytes (16 for std140, 8 or 16 for std430), and MUST drive the emitted MSL
/// row count — never assume std140's 16. spirv-cross emits `float{cols}x{rows'}`
/// where:
///   rows' = (rows == 3) ? 3 : MatrixStride / column_scalar_size
/// An MSL `float3` column already occupies a 16-byte-aligned slot, so 3-row
/// matrices keep their row count; a 2-row column is `float2` (8 B), so it stays
/// 2 rows under std430 (stride 8) but is widened to 4 rows under std140
/// (stride 16). Verified against the oracle for std140 AND std430:
///   std140 (stride 16): mat2→float2x4 mat3→float3x3 mat4→float4x4
///                       mat2x3→float2x3 mat2x4→float2x4 mat3x2→float3x4
///                       mat3x4→float3x4 mat4x2→float4x4 mat4x3→float4x3
///   std430 (stride 8) : mat2→float2x2 mat3x2→float3x2 mat4x2→float4x2
/// Only the 32-bit float component type is implemented; any other component
/// (half/double) — or a missing/odd MatrixStride — returns an honest error
/// rather than a silent-wrong layout.
fn mslMatrixMemberType(m: *const ParsedModule, mat_inst: Instruction, matrix_stride: ?u32, alloc: std.mem.Allocator) ![]const u8 {
    const cols = mat_inst.words[3];
    const col_ty = getDef(m, mat_inst.words[2]) orelse return error.UnsupportedUboMemberLayout;
    if (col_ty.op != .TypeVector) return error.UnsupportedUboMemberLayout;
    // The column scalar must be 32-bit float (4 bytes).
    const scalar = getDef(m, col_ty.words[2]);
    const is_f32 = if (scalar) |s| (s.op == .TypeFloat and !(s.words.len > 2 and s.words[2] == 16)) else false;
    if (!is_f32) return error.UnsupportedUboMemberLayout;
    const scalar_size: u32 = 4;
    const rows: u32 = col_ty.words[3];
    // The real column stride drives the row count. Without it we cannot know the
    // layout (std140 vs std430 differ for 2-row matrices) — fail loudly.
    const stride = matrix_stride orelse return error.UnsupportedUboMemberLayout;
    if (stride == 0 or stride % scalar_size != 0) return error.UnsupportedUboMemberLayout;
    const rows_prime: u32 = if (rows == 3) 3 else stride / scalar_size;
    if (cols < 2 or cols > 4 or rows_prime < 2 or rows_prime > 4)
        return error.UnsupportedUboMemberLayout;
    return std.fmt.allocPrint(alloc, "float{d}x{d}", .{ cols, rows_prime });
}

/// Look up the SPIR-V `MatrixStride` decoration (column stride in bytes) on a
/// struct member, returning null if absent.
fn memberMatrixStride(m: *const ParsedModule, struct_id: u32, member_index: u32) ?u32 {
    for (m.instructions) |inst| {
        if (inst.op == .MemberDecorate and inst.words.len >= 5 and
            inst.words[1] == struct_id and inst.words[2] == member_index)
        {
            const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
            if (dec == .matrix_stride) return inst.words[4];
        }
    }
    return null;
}

/// True if struct member `member_index` carries the SPIR-V `RowMajor`
/// decoration (decoration 4). Mirrors `memberMatrixStride`. The default
/// (`ColMajor`, decoration 5, or no decoration) returns false. A row-major
/// matrix is stored TRANSPOSED relative to its logical shape, so every read
/// must be transposed back — see `findRowMajorMatrix` / `writeMatrixTail`.
fn memberIsRowMajor(m: *const ParsedModule, struct_id: u32, member_index: u32) bool {
    for (m.instructions) |inst| {
        if (inst.op == .MemberDecorate and inst.words.len >= 4 and
            inst.words[1] == struct_id and inst.words[2] == member_index)
        {
            const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
            if (dec == .row_major) return true;
        }
    }
    return false;
}

/// True if `type_id` is a NON-square matrix (column count != row count).
/// A row-major non-square matrix needs SWAPPED member dimensions in MSL
/// (e.g. `mat3x4` stored as `float4x3`), which is not yet implemented; the
/// declaration emitter rejects it with an honest error instead of emitting a
/// column-major-shaped member (silent-wrong). Square row-major matrices are
/// fully handled by transposing reads (`findRowMajorMatrix`).
fn matrixIsNonSquare(m: *const ParsedModule, type_id: u32) bool {
    const mt = getDef(m, type_id) orelse return false;
    if (mt.op != .TypeMatrix) return false;
    const colvec = getDef(m, mt.words[2]) orelse return false;
    if (colvec.op != .TypeVector) return false;
    return mt.words[3] != colvec.words[3]; // cols != rows
}

/// Reject every `row_major` matrix whose MSL layout we cannot yet emit
/// correctly: a NON-square matrix (or non-square matrix array element) needs
/// SWAPPED member dimensions (e.g. mat3x4 -> float4x3). Returns an honest error
/// instead of letting the declaration emitter produce a column-major-shaped
/// member with untransposed access (silent-wrong). Scans ALL structs, so it also
/// covers NESTED structs, which are declared through a shared path that bypasses
/// the top-level member emitter. Square row_major matrices are handled by
/// transposing reads (see findRowMajorMatrix).
fn checkUnsupportedRowMajor(m: *const ParsedModule) !void {
    for (m.instructions) |inst| {
        if (inst.op != .TypeStruct or inst.words.len < 2) continue;
        const struct_id = inst.words[1];
        for (inst.words[2..], 0..) |member_tid, i| {
            if (!memberIsRowMajor(m, struct_id, @intCast(i))) continue;
            if (arrayMatrixElement(m, member_tid)) |mtid| {
                if (matrixIsNonSquare(m, mtid)) return error.UnsupportedRowMajorMatrix;
            }
        }
    }
}

/// Reject GLSL features that have NO valid Metal Shading Language form, so the
/// cross-compiler fails loud with a precise "unsupported feature" error instead
/// of emitting MSL that references an identifier Metal has never heard of (the
/// silent-wrong class: exit 0, then makeLibrary rejects it deep in the Metal
/// compiler with an opaque diagnostic the user cannot map back to their GLSL).
///
/// Scoped narrowly to constructs that are genuinely unrepresentable in MSL for
/// THIS stage, never to ones we simply have not implemented yet: a false
/// "unsupported" that rejects a shader we could compile is a coverage
/// regression, so each gate keys on a precise SPIR-V signature.
///
/// Currently gates:
///  - Fragment barycentric coordinates (gl_BaryCoordEXT / gl_BaryCoordNV): Metal
///    has no fragment barycentric builtin, so the emitter would otherwise write a
///    bare `gl_BaryCoord*` identifier that does not exist.
///  - ARM tensor types (GL_ARM_tensors: tensorARM<>, tensorReadARM,
///    tensorSizeARM): Metal has no tensor type at all, so tensor operands lower to
///    undeclared identifiers.
///  - gl_ClipDistance / gl_CullDistance READ IN A FRAGMENT SHADER: Metal exposes
///    clip_distance only as a vertex OUTPUT ([[clip_distance]]); there is no
///    fragment input for it. Scoped to the fragment stage on purpose: vertex
///    clip/cull output IS expressible in MSL, so gating it would be a false
///    "unsupported" (it is a codegen bug to fix, not a limit to declare).
fn checkUnsupportedMslFeatures(m: *const ParsedModule) !void {
    const is_fragment = m.execution_model == .Fragment;
    for (m.instructions) |inst| {
        // ARM tensor type: no Metal equivalent exists in any stage.
        if (inst.op == .TypeTensorARM) return error.UnsupportedTensor;

        if (inst.op != .Decorate or inst.words.len < 4) continue;
        if (inst.words[2] != @intFromEnum(spirv.Decoration.built_in)) continue;
        const bi = inst.words[3];
        if (bi == @intFromEnum(spirv.BuiltIn.bary_coord_khr) or
            bi == @intFromEnum(spirv.BuiltIn.bary_coord_no_persp_khr))
        {
            return error.UnsupportedBarycentric;
        }
        if (is_fragment and
            (bi == @intFromEnum(spirv.BuiltIn.clip_distance) or
                bi == @intFromEnum(spirv.BuiltIn.cull_distance)))
        {
            return error.UnsupportedFragmentClipCullDistance;
        }
    }
}

/// MSL type for uniform buffer struct members.
/// Uses packed_float3 instead of float3 to match SPIR-V offset layout.
fn mslPackedType(m: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(m, type_id) orelse return error.UnsupportedOpcode;
    if (inst.op == .TypeVector) {
        const count = inst.words[3];
        const scalar = try mslType(m, inst.words[2], names, alloc);
        // 3-component vectors need packed_ prefix for tight packing in UBO structs
        if (count == 3) {
            if (std.mem.eql(u8, scalar, "float")) return "packed_float3";
            if (std.mem.eql(u8, scalar, "half")) return "packed_half3";
            if (std.mem.eql(u8, scalar, "int")) return "packed_int3";
            if (std.mem.eql(u8, scalar, "uint")) return "packed_uint3";
        }
    }
    if (inst.op == .TypeMatrix) {
        // A matrix's correct MSL row count depends on its MatrixStride
        // decoration (std140 vs std430 differ), which this stride-less helper
        // does not have. Callers with struct-member context resolve matrices
        // via mslMatrixMemberType(stride); reaching here means we'd have to
        // GUESS the layout — fail loudly instead of emitting silent-wrong.
        return error.UnsupportedUboMemberLayout;
    }
    return try mslType(m, type_id, names, alloc);
}

// ---- MSL type resolution ----
fn mslGetArraySuffix(m: *const ParsedModule, ptr_type_id: u32) ![]const u8 {
    // multi_dim=true: emit ALL nested TypeArray dimensions (`[3][4]`, not just the
    // outer `[3]`). 1-D arrays are unaffected; multi-D arrays otherwise dropped their
    // inner dims and were indexed `m[i][j]` against a 1-D decl (multi_dim_array).
    return common.commonGetArraySuffix(m.instructions, m.id_defs, ptr_type_id, true);
}

/// Loop-header OpPhi (the loop counter): materialized as a mutable variable so it
/// is not frozen at its constant init value (#phi-loop). Mirrors spirv_to_hlsl.zig.
const PhiInfo = struct { result_id: u32, type_id: u32, init_id: u32, update_id: u32 };

// Per-emitBody loop-phi state (set at the start of emitBody, read by emitWhileLoopMSL).
threadlocal var g_loop_phis: ?*const std.AutoHashMap(usize, std.ArrayList(PhiInfo)) = null;
threadlocal var g_phi_hdr: ?*const std.AutoHashMap(u32, usize) = null;
threadlocal var g_deferred_hdr: ?*const std.AutoHashMap(usize, void) = null;
// Selection-merge phis the BranchConditional handler already materialized as a
// `_phi` var. The generic OpPhi handler must NOT re-alias these to a branch-local
// incoming value (which is out of scope after the merge) — it would undo the
// materialization and reintroduce the undeclared-identifier bug.
threadlocal var g_materialized_phis: ?*std.AutoHashMap(u32, void) = null;
// Phi variables already DECLARED in this emit. Distinct from g_materialized_phis,
// which also means "renamed" and is written by non-declaring passes. See mslPhiDeclare.
threadlocal var g_declared_phis: ?*std.AutoHashMap(u32, void) = null;

// #413: loop-phi update temps defined INSIDE the loop have their declaration
// hoisted above the loop header (declare-then-assign split) — the top-of-loop
// carry copy (#237) otherwise reads them before their declaration and out of
// scope. See spirv_cross_common.zig.
threadlocal var g_loop_hoists: ?*const std.AutoHashMap(usize, std.ArrayList(common.HoistedPhiSrc)) = null;
threadlocal var g_hoisted_ids: ?*const std.AutoHashMap(u32, void) = null;
threadlocal var g_hoist_stripping: bool = false;

// #multi-return: spirv-opt lowers early/multi-return to an OpSwitch-on-constant
// wrapper whose merge block holds the return-value phi(s). Those phis' predecessors
// are NESTED inside the single case body — they branch straight to the switch
// merge (the early return), not to a case label. emitSwitchPhiCaseCopy only
// matches case labels, so the nested preds' assignments were dropped → the
// return-value var stayed uninitialized (garbage, maxdiff 255). This context
// (set around each switch's case-body emission, saved/restored for nesting) lets
// emitBlock emit the switch-merge phi copy at each branch-to-switch-merge point
// inside the case body. Mirrors the loop-merge-phi carry-on-break pattern.
const SwitchPhiCtx = struct { merge_label: u32, phis: []const Instruction };
threadlocal var g_switch_ctx: ?SwitchPhiCtx = null;

// #loop-break-out-of-switch: a branch from INSIDE a loop body to the enclosing
// switch's merge block (a multi-level break, out of BOTH the loop and the switch)
// cannot lower to a bare `break;` in C -- the break only exits the LOOP, and the
// code after the loop in the case then runs and clobbers the switch-merge phi
// (silent-wrong: the early-exit path rendered the fall-through value). spirv-val
// rejects the shape (a loop-construct block may only branch within the construct,
// to the loop's own merge, or to the continue target), so a VALID module never
// carries it -- but zioshade ingests unvalidated SPIR-V, and whatever it accepts
// must be honest. The lowering is the classic flag idiom (what spirv-cross does
// for C-family multi-level breaks): each loop walker that finds such a branch
// declares `bool _swbrk_N = false;` above the loop, every break-to-switch-merge
// site inside the region sets it before its `break;`, and right after the loop
// `if (_swbrk_N) break;` exits the switch (or, for a loop nested in another loop,
// sets the parent flag and breaks ONE level -- each walker's post-loop guard
// carries it the rest of the way out). Null while not inside an armed loop.
threadlocal var g_swbrk_flag: ?[]const u8 = null;

// #switch-fallthrough: a case-target block's cross-case chain phi (spirv-opt's
// fallthrough lowering). `block` = the case-target block the phi lives at;
// `entry_value` = the incoming from before the switch (the "initial"); `literal`
// = the OpSwitch literal for `block` (for the entry-init `if(sel==literal)`).
const ChainPhiEntry = struct { phi: Instruction, block: u32, entry_value: u32, literal: i64 };
threadlocal var g_switch_chain: ?[]const ChainPhiEntry = null;

// #early-return-in-loop: a return inside a loop (spirv-opt) stores the return
// value then branches to the LOOP merge from a NON-TRIVIAL block (it carries the
// store, so it isn't a Label+Branch trivial-break). That block goes through
// emitBlock (the general if/else handler), which didn't know it was a loop-break
// → no loop-merge-phi copy + no `break`, so the loop kept iterating and the
// "did we return?" flag stayed stale (early_return2, maxdiff). This context (set
// around each loop's body emission, saved/restored for nesting) lets emitBlock,
// at a branch to the loop merge, emit the loop-merge-phi copy + a `break;`.
// #latch-phi: latch_phis carries the loop's latch (continue-block) phis so the
// same context can wire copies at emitBlock's branch-to-continue (below), the
// way `phis` already does for the loop-merge break. Empty for do-while loops,
// where latch_mphis is not collected (the back-edge conditional owns the latch).
const LoopMergeCtx = struct { merge_label: u32, phis: []const Instruction, continue_label: u32, latch_phis: []const Instruction };
threadlocal var g_loop_merge_ctx: ?LoopMergeCtx = null;

// Bound on emitWhileLoopMSL's mutual recursion with emitBlock. Same guard, and same
// reason, as spirv_to_glsl.zig's max_emit_while_depth (PR #522): on some valid-but-
// pathological loop structures the recursion does not advance (emitWhileLoopMSL emits
// the body, emitBlock walks a branch back into the SAME loop header, and around again),
// so it exhausts the stack and dies by SIGSEGV -- a crash on spirv-val-valid input, i.e.
// a mandate violation. Refuse loudly instead. Real shaders nest loops far below this
// (GraphicsFuzz and real apps are under 100), so the bound is a safety net, not a
// capability limit. This fixes the CRASH; compiling these shaders correctly rather than
// honest-erroring is a separate loop-lowering follow-up.
const max_emit_while_depth: u32 = 256;
threadlocal var g_ewl_depth: u32 = 0;

// Maps a flattened interface-block Input member to its main0_in field name so
// buildAccessExpr can rewrite `vin.member` (an OpAccessChain into a struct-typed
// Input var, which has no MSL declaration) to `in.<blockinstance>_<member>`.
// Key packs (block_var_id, member_index); value is the flat field name (no `in.`
// prefix). Set before function emission (#478). Fragment interface blocks only.
threadlocal var g_block_flat: ?*const std.AutoHashMap(u64, []const u8) = null;

// #491: OpSampledImage combines a bare image + a sampler into a sampled-image value.
// ImageSample* needs BOTH: `<image>.sample(<sampler>, ...)`. For a resource the sampler
// is the paired `<name>Smplr`; for a bare-image+separate-sampler it's the OpSampledImage
// sampler operand (recorded here, keyed by the OpSampledImage result id).
threadlocal var g_sampled_sampler: ?*std.AutoHashMap(u32, []const u8) = null;

// #493: OpTypeImage type-ids that are USED as depth (via a depth OpSampledImage, e.g.
// GL_EXT samplerless `sampler2DShadow(texture2D, samplerShadow)`) despite Depth=0. Such
// textures must be depth2d for sample_compare. Populated by a scan in spirvToMSL.
threadlocal var g_depth_tex_types: ?*const std.AutoHashMap(u32, void) = null;
fn blockFlatKey(var_id: u32, member: u32) u64 {
    return (@as(u64, var_id) << 20) | @as(u64, member);
}

// Sentinel member index under which collectStageInputs stores the flattened
// Input var's ORIGINAL source name. Needed because the body-emit rename
// (spirvToMSL ~line 3043) overwrites names[var_id] = "in.<last-leaf>" -- with
// recursive flatten several leaves share one var_id, so names[var] is clobbered.
// Reconstruction / access-expr sites must read the original name via this key.
const FLAT_VAR_NAME_MEMBER: u32 = 0xFFFFF;

// #500 recursive flatten: for a flattened Input struct var, consume the LEADING
// constant struct-member index ids and return the deterministic leaf-field name
// (`<var>_<m0>_<m1>...`, no `in.` prefix), how many were consumed, and the
// terminal type id. Stops at the first index that does not descend a struct
// (vector component / array / non-constant) or at end-of-indices. Returns null
// if `base_id` is not a flattened Input struct var. If the chain ends on a
// struct (a sub-struct value), term_type is a TypeStruct and the name is the
// deepest prefix -- the OpLoad handler reconstructs sub-structs; leaf
// expressions only result when term_type is scalar/vector.
const FlatConsume = struct { name: []const u8, consumed: usize, term_type: u32 };
fn mslConsumeFlatInputIndices(alloc: std.mem.Allocator, m: *const ParsedModule, base_id: u32, indices: []const u32) ?FlatConsume {
    const bf = g_block_flat orelse return null;
    const var_name = bf.get(blockFlatKey(base_id, FLAT_VAR_NAME_MEMBER)) orelse return null; // not a flattened struct var
    var cur_type = resolvePointee(m, base_id) orelse return null;
    var name: []const u8 = std.fmt.allocPrint(alloc, "{s}", .{var_name}) catch return null;
    var consumed: usize = 0;
    for (indices) |index_id| {
        const idef = getDef(m, index_id) orelse break;
        if (idef.op != .Constant or idef.words.len <= 3) break;
        const val = idef.words[3];
        const tdef = getDef(m, cur_type) orelse break;
        if (tdef.op != .TypeStruct or val + 2 >= tdef.words.len) break;
        var nbuf: [32]u8 = undefined;
        const mname = getMemberName(m, cur_type, val, &nbuf);
        name = std.fmt.allocPrint(alloc, "{s}_{s}", .{ name, mname }) catch break;
        cur_type = tdef.words[val + 2];
        consumed += 1;
    }
    const safe = mslSanitizeName(alloc, name) catch name;
    return .{ .name = safe, .consumed = consumed, .term_type = cur_type };
}

// #500 recursive flatten: emit a nested brace initializer reconstructing
// `struct_type_id` from flattened Input leaves. `prefix` is the accumulated
// `<var>_<...>`` path TO this struct (already includes var + ancestors). Emits
// `{ in.<prefix>_<leaf0>, {substruct...}, ... }`.
fn mslEmitFlatStructInit(m: *const ParsedModule, w: anytype, alloc: std.mem.Allocator, prefix: []const u8, struct_type_id: u32) !void {
    try w.writeAll("{ ");
    const sdef = getDef(m, struct_type_id) orelse {
        try w.writeAll("}");
        return;
    };
    if (sdef.op != .TypeStruct) {
        try w.print("in.{s} }}", .{prefix});
        return;
    }
    const nms: u32 = @intCast(sdef.words.len - 2);
    var mi: u32 = 0;
    var first = true;
    while (mi < nms) : (mi += 1) {
        const mtype = sdef.words[mi + 2];
        var nbuf: [32]u8 = undefined;
        const mname = getMemberName(m, struct_type_id, mi, &nbuf);
        const child_prefix = try std.fmt.allocPrint(alloc, "{s}_{s}", .{ prefix, mname });
        if (!first) try w.writeAll(", ");
        first = false;
        if (getDef(m, mtype)) |mt| {
            if (mt.op == .TypeStruct) {
                try mslEmitFlatStructInit(m, w, alloc, child_prefix, mtype);
                continue;
            }
        }
        try w.print("in.{s}", .{child_prefix});
    }
    try w.writeAll(" }");
}

// #500 recursive flatten: if `inst` is an OpLoad of a whole- or sub-struct
// flattened Input, reconstruct it from leaf fields (nested brace init) and
// return true. Whole: pid is the flat var. Sub-struct: pid is an OpAccessChain
// into a flat var whose index chain terminates at a struct. Called at the TOP
// of the .Load handler (before is_special) so sub-struct loads (pid not a
// Variable) are caught.
fn tryReconstructFlatStructLoad(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), w: anytype, alloc: std.mem.Allocator, inst: common.Instruction) !bool {
    const rt = getDef(m, inst.words[1]);
    if (rt == null or rt.?.op != .TypeStruct or rt.?.words.len <= 2) return false;
    const bf = g_block_flat orelse return false;
    const pid = inst.words[3];
    const rn = names.get(inst.words[2]) orelse "v";
    // Whole-struct load: pid is the flattened Input var (sentinel -> its name).
    if (bf.get(blockFlatKey(pid, FLAT_VAR_NAME_MEMBER))) |vname| {
        const rtt = try mslValueType(m, inst.words[1], names, alloc);
        try w.print("    {s} {s} = ", .{ rtt, rn });
        try mslEmitFlatStructInit(m, w, alloc, vname, inst.words[1]);
        try w.writeAll(";\n");
        return true;
    }
    // Sub-struct load: pid is an OpAccessChain into a flattened Input var.
    if (getDef(m, pid)) |ac| {
        if (ac.op == .AccessChain and ac.words.len >= 5) {
            const ac_base = ac.words[3];
            if (bf.get(blockFlatKey(ac_base, FLAT_VAR_NAME_MEMBER)) != null) {
                if (mslConsumeFlatInputIndices(alloc, m, ac_base, ac.words[4..])) |r| {
                    if (getDef(m, r.term_type)) |tt| {
                        if (tt.op == .TypeStruct) {
                            const rtt = try mslValueType(m, inst.words[1], names, alloc);
                            try w.print("    {s} {s} = ", .{ rtt, rn });
                            try mslEmitFlatStructInit(m, w, alloc, r.name, inst.words[1]);
                            try w.writeAll(";\n");
                            return true;
                        }
                    }
                }
            }
        }
    }
    return false;
}

// Input builtin variables whose GLSL array indexing must be dropped because the
// Metal builtin is a SCALAR: gl_SampleMaskIn[0] -> gl_SampleMaskIn, since
// [[sample_mask]] is a uint, not an array. (#481)
threadlocal var g_scalar_builtin_vars: ?*const std.AutoHashMap(u32, void) = null;

// When true, emitFunction emits a non-entry function's SIGNATURE followed by `;`
// (a C forward prototype) and returns before the body, so mutually-recursive /
// forward-referencing functions resolve. Set only during the prototype pass and
// only when a forward call actually exists (#480).
threadlocal var g_proto_only: bool = false;

// True when the shader has location stage inputs, so the `main0_in in` struct is
// threaded into every non-entry function's signature. Read at OpFunctionCall to
// append `in` to the call args (mirrors how cbuffers/textures are threaded). Set
// once before function emission; a threadlocal avoids plumbing the flag through
// the whole emitBody/emitBlock/emitInstruction call chain (#476).
threadlocal var g_has_stage_in: bool = false;

// #489: when a fragment has a color output, thread `thread <type>& <name>` into every
// non-entry helper too (mirrors the main0_in threading), so a helper that writes the
// output (e.g. shader-debug `func0` -> `ov`) resolves it. Set in spirvToMSL; read at the
// helper signature + OpFunctionCall. Null when there is no fragment output.
threadlocal var g_frag_out_type: ?[]const u8 = null;
threadlocal var g_frag_out_name: ?[]const u8 = null;

// #472: multi-output fragment outputs (MRT/FragDepth/SampleMask/stencil/dual-source).
// Set ONLY for fragments that take the multi-field main0_out path; null for the single-
// color common case (which keeps g_frag_out_type/name + the byte-identical legacy path).
// Consumed by the non-entry helper signature emitter + the OpFunctionCall arg appender.
threadlocal var g_frag_outputs: ?[]const FragOutput = null;

// #489 (builtin threading): the gl_FragCoord builtin is renamed to `_fragCoord` and
// threaded into helpers too, so a helper that reads it (raymarch `scene()`) resolves it.
// Set in spirvToMSL (the rename must precede helper emission); null when no FragCoord.
threadlocal var g_frag_coord_ty: ?[]const u8 = null;

/// A mutated Private global promoted to a local in the entry impl and threaded into
/// every helper as `thread T&`.
const PrivGlobal = struct { var_id: u32, name: []const u8, ty: []const u8, init_id: ?u32 };

/// Mutated Private globals threaded through helper signatures. Fragment only: this
/// must match, exactly, the set the fragment entry path DECLARES as locals, or a
/// helper takes a parameter its caller cannot supply. `collectThreadedPrivGlobals` is
/// the single predicate both use, so the two cannot drift apart.
threadlocal var g_priv_globals: ?[]const PrivGlobal = null;

fn phiTypeNameMSL(m: *const ParsedModule, type_id: u32) []const u8 {
    const tinst = getDef(m, type_id) orelse return "int";
    switch (tinst.op) {
        .TypeBool => return "bool",
        .TypeInt => return if (tinst.words.len > 3 and tinst.words[3] != 0) "int" else "uint",
        .TypeFloat => return if (tinst.words.len > 2 and tinst.words[2] == 16) "half" else "float",
        .TypeVector => {
            const s = phiTypeNameMSL(m, tinst.words[2]);
            const c = tinst.words[3];
            if (c < 1 or c > 4) return "int";
            const i: usize = c;
            if (std.mem.eql(u8, s, "float")) return ([_][]const u8{ "", "float", "float2", "float3", "float4" })[i];
            if (std.mem.eql(u8, s, "half")) return ([_][]const u8{ "", "half", "half2", "half3", "half4" })[i];
            if (std.mem.eql(u8, s, "int")) return ([_][]const u8{ "", "int", "int2", "int3", "int4" })[i];
            if (std.mem.eql(u8, s, "uint")) return ([_][]const u8{ "", "uint", "uint2", "uint3", "uint4" })[i];
            if (std.mem.eql(u8, s, "bool")) return ([_][]const u8{ "", "bool", "bool2", "bool3", "bool4" })[i];
            return "int";
        },
        else => return "int",
    }
}

fn isDeferredHdrMSL(idx: usize) bool {
    const dh = g_deferred_hdr orelse return false;
    return dh.contains(idx);
}

/// If `inst` is a loop-header phi, emit its mutable-variable declaration and
/// return true (caller should `continue`).
fn tryEmitLoopPhiDeclMSL(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator, indent: []const u8) !bool {
    if (inst.op != .Phi) return false;
    const ph = g_phi_hdr orelse return false;
    const lmi = ph.get(inst.words[2]) orelse return false;
    const lp = g_loop_phis orelse return false;
    const plist = lp.get(lmi) orelse return false;
    for (plist.items) |pi| {
        if (pi.result_id != inst.words[2]) continue;
        const tyname = phiTypeNameMSL(m, pi.type_id);
        if (names.get(pi.result_id) == null) {
            // `_phi` suffix, matching mslPhiVarName: a plain `v{rid}` is ID-derived and
            // can numerically collide with a counter-derived temp name (phi %83 -> "v83"
            // vs the 83rd temp "v83") -> both declared at function scope -> Metal
            // redefinition error (invalid MSL; found on the graphicsfuzz_028 round-trip).
            const nm = std.fmt.allocPrint(alloc, "v{d}_phi", .{pi.result_id}) catch "vphi";
            if (names.fetchPut(pi.result_id, nm) catch null) |old| alloc.free(old.value);
        }
        const vname = names.get(pi.result_id) orelse "vphi";
        const init_name = names.get(pi.init_id) orelse "0";
        // #413: an inner loop's phi variable can be an OUTER loop's carry
        // source; its declaration was hoisted above the outer loop, so only
        // the init assignment is emitted here.
        const hoisted = if (g_hoisted_ids) |h| h.contains(pi.result_id) else false;
        if (hoisted) {
            try w.print("{s}{s} = {s};\n", .{ indent, vname, init_name });
        } else {
            try w.print("{s}{s} {s} = {s};\n", .{ indent, tyname, vname, init_name });
        }
    }
    return true;
}

fn mslType(m: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(m, type_id) orelse return error.UnsupportedOpcode;
    return switch (inst.op) {
        .TypeVoid => "void",
        .TypeBool => "bool",
        .TypeInt => if (inst.words.len > 3 and inst.words[3] != 0) "int" else "uint",
        .TypeFloat => if (inst.words.len > 2 and inst.words[2] == 16) "half" else "float",
        .TypeVector => {
            const scalar = try mslType(m, inst.words[2], names, alloc);
            const count = inst.words[3];
            if (std.mem.eql(u8, scalar, "float")) {
                if (count >= 1 and count <= 4) return ([_][]const u8{ "", "float", "float2", "float3", "float4" })[count];
            } else if (std.mem.eql(u8, scalar, "half")) {
                if (count >= 1 and count <= 4) return ([_][]const u8{ "", "half", "half2", "half3", "half4" })[count];
            } else if (std.mem.eql(u8, scalar, "int")) {
                if (count >= 1 and count <= 4) return ([_][]const u8{ "", "int", "int2", "int3", "int4" })[count];
            } else if (std.mem.eql(u8, scalar, "uint")) {
                if (count >= 1 and count <= 4) return ([_][]const u8{ "", "uint", "uint2", "uint3", "uint4" })[count];
            } else if (std.mem.eql(u8, scalar, "bool")) {
                if (count >= 1 and count <= 4) return ([_][]const u8{ "", "bool", "bool2", "bool3", "bool4" })[count];
            }
            return std.fmt.allocPrint(alloc, "{s}{d}", .{ scalar, count });
        },
        .TypeMatrix => {
            const cols = inst.words[3];
            const ct = getDef(m, inst.words[2]);
            const rows: u32 = if (ct) |c| c.words[3] else cols;
            if (cols == rows) {
                if (cols == 2) return "float2x2";
                if (cols == 3) return "float3x3";
                if (cols == 4) return "float4x4";
            }
            if (cols == 2 and rows == 3) return "float2x3";
            if (cols == 2 and rows == 4) return "float2x4";
            if (cols == 3 and rows == 2) return "float3x2";
            if (cols == 3 and rows == 4) return "float3x4";
            if (cols == 4 and rows == 2) return "float4x2";
            if (cols == 4 and rows == 3) return "float4x3";
            return std.fmt.allocPrint(alloc, "float{d}x{d}", .{ cols, rows });
        },
        .TypeArray, .TypeRuntimeArray => mslType(m, inst.words[2], names, alloc),
        .TypePointer => if (inst.words.len > 3) mslType(m, inst.words[3], names, alloc) else return error.UnsupportedOpcode,
        .TypeStruct => names.get(type_id) orelse "Struct",
        else => return error.UnsupportedOpcode,
    };
}

/// MSL **value** type for `type_id`. Identical to `mslType` except that arrays
/// are spelled as `spvUnsafeArray<elem, N>` (recursing for nested arrays →
/// `spvUnsafeArray<spvUnsafeArray<T, N2>, N1>`). Metal C-arrays are not
/// assignable, so any array used as a VALUE (whole `OpLoad`/`OpStore`,
/// `OpCopyObject`, array-typed function param/return) must use this template
/// spelling — mirroring `spirv-cross --msl`. Non-array types fall through to
/// `mslType`, so existing scalar/vector/matrix/struct spellings are unchanged.
fn mslValueType(m: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(m, type_id) orelse return mslType(m, type_id, names, alloc);
    if (inst.op == .TypeArray and inst.words.len > 3) {
        const elem = try mslValueType(m, inst.words[2], names, alloc);
        // B5: read the length constant honestly. A `spvUnsafeArray<T, Num>` needs
        // a concrete compile-time `Num`. Only a plain `OpConstant` (scalar int
        // literal at words[3]) gives that. A spec-constant length, an
        // `OpSpecConstantOp`-computed length, or a missing/zero-word def must NOT
        // silently default to 1 (a silent-wrong sizing); fail loud instead.
        // Deferred to a frontend fix -- see zioshade/zioshade#173.
        const len_def = getDef(m, inst.words[3]) orelse return error.UnresolvableArrayLength;
        if (len_def.op != .Constant or len_def.words.len <= 3) return error.UnresolvableArrayLength;
        const n: u32 = len_def.words[3];
        return std.fmt.allocPrint(alloc, "spvUnsafeArray<{s}, {d}>", .{ elem, n });
    }
    return mslType(m, type_id, names, alloc);
}

/// True if the array variable / constant `id` is used as a whole-array VALUE
/// anywhere in the module — i.e. there is an `OpLoad` of a pointer that roots at
/// `id` whose result type is a `TypeArray`. Such a whole-array load (and the
/// copy/store that consumes it) is illegal on a Metal C-array, so both the
/// source and destination must be spelled with `spvUnsafeArray<…>` instead.
/// Recomputed on demand (no shared mutable state) so each emit site can decide
/// independently and consistently.
fn arrayLoadedAsValue(m: *const ParsedModule, id: u32) bool {
    for (m.instructions) |inst| {
        if (inst.op != .Load or inst.words.len < 4) continue;
        const rt = getDef(m, inst.words[1]) orelse continue;
        if (rt.op != .TypeArray) continue;
        if (pointerRootsAt(m, inst.words[3], id)) return true;
    }
    return false;
}

/// True if `var_inst` is a Function-storage array `OpVariable` that is the
/// destination of a whole-array `OpStore` whose value is itself a whole-array
/// VALUE — a whole-array `OpLoad`, or an `OpSelect`/`OpCopyObject` of array type
/// (e.g. `float local[N] = LUT;` or `float la[N] = cond ? A : B;`). These locals
/// must be declared as `spvUnsafeArray<…>` so the copy is a legal struct
/// assignment rather than an illegal C-array copy. The store VALUE's result type
/// is confirmed to be a `TypeArray` (B3) so a scalar store never matches.
fn localArrayValueCopyDest(m: *const ParsedModule, var_inst: Instruction) bool {
    if (var_inst.op != .Variable or var_inst.words.len < 4) return false;
    const sc: spirv.StorageClass = @enumFromInt(var_inst.words[3]);
    if (sc != .Function) return false;
    const ptr = getDef(m, var_inst.words[1]) orelse return false;
    if (ptr.op != .TypePointer or ptr.words.len < 4) return false;
    const pointee = getDef(m, ptr.words[3]) orelse return false;
    if (pointee.op != .TypeArray) return false;
    const var_id = var_inst.words[2];
    for (m.instructions) |inst| {
        if (inst.op != .Store or inst.words.len < 3) continue;
        if (inst.words[1] != var_id) continue;
        const val = getDef(m, inst.words[2]) orelse continue;
        switch (val.op) {
            .Load, .Select, .CopyObject, .CompositeConstruct => {
                // B3: only a value whose RESULT TYPE is an array forces the
                // template spelling; a scalar load/select into an array element
                // (which would not have an array result type) must not match.
                if (val.words.len < 2) continue;
                const vt = getDef(m, val.words[1]) orelse continue;
                if (vt.op == .TypeArray) return true;
            },
            else => {},
        }
    }
    return false;
}

/// True if `var_inst` is a Function-storage array `OpVariable` whose id roots a
/// whole-array `OpLoad` (i.e. it is the SOURCE of a whole-array value copy such
/// as the `a` in `float b[N] = a;`). A C-array cannot be copy-assigned in Metal,
/// so the source must be declared `spvUnsafeArray<…>` to match the destination.
fn localArrayValueCopySource(m: *const ParsedModule, var_inst: Instruction) bool {
    if (var_inst.op != .Variable or var_inst.words.len < 4) return false;
    const sc: spirv.StorageClass = @enumFromInt(var_inst.words[3]);
    if (sc != .Function) return false;
    const ptr = getDef(m, var_inst.words[1]) orelse return false;
    if (ptr.op != .TypePointer or ptr.words.len < 4) return false;
    const pointee = getDef(m, ptr.words[3]) orelse return false;
    if (pointee.op != .TypeArray) return false;
    return arrayLoadedAsValue(m, var_inst.words[2]);
}

/// Follow a pointer (through `OpAccessChain`/`OpCopyObject`) to the root
/// `OpVariable`/`OpConstant*` def it ultimately addresses. Returns null if the
/// root cannot be resolved.
fn pointerRootDef(m: *const ParsedModule, start_id: u32) ?Instruction {
    var id = start_id;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        const inst = getDef(m, id) orelse return null;
        switch (inst.op) {
            .AccessChain, .CopyObject => {
                if (inst.words.len < 4) return inst;
                id = inst.words[3];
            },
            else => return inst,
        }
    }
    return null;
}

/// True if the whole-array VALUE loaded through pointer `pid` comes from a source
/// the backend has declared as `spvUnsafeArray<…>` — i.e. a Function-storage
/// array local that is itself a value-copy SOURCE or DEST, or a const global that
/// is value-copied (materialized as `constant spvUnsafeArray<…>`). Only then is
/// the whole-array load `spvUnsafeArray dst = src;` a legal struct copy. If the
/// source is anything else (a plain `constant T[N]` C-array, a UBO/SSBO member,
/// an array function param, …) the template spelling would NOT match and the
/// caller must NOT silently emit it (see `.Load`).
fn arrayLoadRootIsUnsafeArray(m: *const ParsedModule, pid: u32) bool {
    const root = pointerRootDef(m, pid) orelse return false;
    if (root.op != .Variable or root.words.len < 4) return false;
    const sc: spirv.StorageClass = @enumFromInt(root.words[3]);
    if (sc == .Function) {
        // A value-copied function local (source or dest) is spvUnsafeArray.
        return localArrayValueCopySource(m, root) or localArrayValueCopyDest(m, root);
    }
    if (sc == .Private) {
        // A const-initialized Private global is materialized at module scope; it
        // is `constant spvUnsafeArray<…>` only when it is value-copied.
        if (common.constInitializedPrivateVar(m, root) != null)
            return arrayLoadedAsValue(m, root.words[2]);
    }
    return false;
}

/// Whether the module needs the `spvUnsafeArray<T,Num>` template preamble: true
/// when any whole-array VALUE op occurs — a whole-array `OpLoad`, or an
/// `OpCompositeConstruct`/`OpSelect`/`OpCopyObject` whose result type is an array
/// (each of which the backend now spells with the template). Any of these forces
/// both ends of the copy to the template spelling.
fn moduleNeedsUnsafeArray(m: *const ParsedModule) bool {
    for (m.instructions) |inst| {
        switch (inst.op) {
            .Load, .CompositeConstruct, .Select, .CopyObject => {
                if (inst.words.len < 2) continue;
                const rt = getDef(m, inst.words[1]) orelse continue;
                if (rt.op == .TypeArray) return true;
            },
            // A MUTATED no-initializer Private array global is threaded as a
            // spvUnsafeArray local (collectThreadedPrivGlobals), so the template
            // must be in the preamble. Read-only const arrays keep their plain
            // `constant T[N]` module-scope path and must NOT pull the template in
            // (it would confuse consumers scanning for the const declaration).
            .Variable => {
                if (inst.words.len < 4 or inst.words.len >= 5) continue;
                if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Private) continue;
                const ptr = getDef(m, inst.words[1]) orelse continue;
                if (ptr.op != .TypePointer or ptr.words.len <= 3) continue;
                const pt = getDef(m, ptr.words[3]) orelse continue;
                if (pt.op != .TypeArray) continue;
                const vid = inst.words[2];
                for (m.instructions) |su| {
                    if (su.op == .Store and su.words.len >= 3 and pointerRootsAt(m, su.words[1], vid)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

/// Metal has no matrix `inverse()` builtin, so GLSL inverse(matN) (GLSL.std.450
/// MatrixInverse=34) is lowered to a generated closed-form cofactor/adjugate helper —
/// the same math the WGSL backend emits (`spvInverse2/3/4`) and spirv-cross's
/// `spvInverseNxN`. The helper is emitted into the preamble at most once per dimension,
/// gated by a module scan (`moduleInverseDims`). Column-major throughout, matching MSL's
/// `floatNxN(col0…)` constructor order.
const spv_inverse2_template =
    \\float2x2 spvInverse2x2(float2x2 m)
    \\{
    \\    float det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
    \\    return float2x2(m[1][1], -m[0][1], -m[1][0], m[0][0]) * (1.0 / det);
    \\}
    \\
    \\
;
const spv_inverse3_template =
    \\float3x3 spvInverse3x3(float3x3 m)
    \\{
    \\    float a = m[0][0]; float b = m[1][0]; float c = m[2][0];
    \\    float d = m[0][1]; float e = m[1][1]; float f = m[2][1];
    \\    float g = m[0][2]; float h = m[1][2]; float i = m[2][2];
    \\    float A = (e * i - f * h);
    \\    float B = (f * g - d * i);
    \\    float C = (d * h - e * g);
    \\    float det = a * A + b * B + c * C;
    \\    float inv_det = 1.0 / det;
    \\    return float3x3(
    \\        A * inv_det,
    \\        B * inv_det,
    \\        C * inv_det,
    \\        (c * h - b * i) * inv_det,
    \\        (a * i - c * g) * inv_det,
    \\        (b * g - a * h) * inv_det,
    \\        (b * f - c * e) * inv_det,
    \\        (c * d - a * f) * inv_det,
    \\        (a * e - b * d) * inv_det);
    \\}
    \\
    \\
;
const spv_inverse4_template =
    \\float4x4 spvInverse4x4(float4x4 m)
    \\{
    \\    float a00 = m[0][0]; float a01 = m[0][1]; float a02 = m[0][2]; float a03 = m[0][3];
    \\    float a10 = m[1][0]; float a11 = m[1][1]; float a12 = m[1][2]; float a13 = m[1][3];
    \\    float a20 = m[2][0]; float a21 = m[2][1]; float a22 = m[2][2]; float a23 = m[2][3];
    \\    float a30 = m[3][0]; float a31 = m[3][1]; float a32 = m[3][2]; float a33 = m[3][3];
    \\    float b00 = a00 * a11 - a01 * a10;
    \\    float b01 = a00 * a12 - a02 * a10;
    \\    float b02 = a00 * a13 - a03 * a10;
    \\    float b03 = a01 * a12 - a02 * a11;
    \\    float b04 = a01 * a13 - a03 * a11;
    \\    float b05 = a02 * a13 - a03 * a12;
    \\    float b06 = a20 * a31 - a21 * a30;
    \\    float b07 = a20 * a32 - a22 * a30;
    \\    float b08 = a20 * a33 - a23 * a30;
    \\    float b09 = a21 * a32 - a22 * a31;
    \\    float b10 = a21 * a33 - a23 * a31;
    \\    float b11 = a22 * a33 - a23 * a32;
    \\    float det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
    \\    float inv_det = 1.0 / det;
    \\    return float4x4(
    \\        ( a11 * b11 - a12 * b10 + a13 * b09) * inv_det,
    \\        (-a01 * b11 + a02 * b10 - a03 * b09) * inv_det,
    \\        ( a31 * b05 - a32 * b04 + a33 * b03) * inv_det,
    \\        (-a21 * b05 + a22 * b04 - a23 * b03) * inv_det,
    \\        (-a10 * b11 + a12 * b08 - a13 * b07) * inv_det,
    \\        ( a00 * b11 - a02 * b08 + a03 * b07) * inv_det,
    \\        (-a30 * b05 + a32 * b02 - a33 * b01) * inv_det,
    \\        ( a20 * b05 - a22 * b02 + a23 * b01) * inv_det,
    \\        ( a10 * b10 - a11 * b08 + a13 * b06) * inv_det,
    \\        (-a00 * b10 + a01 * b08 - a03 * b06) * inv_det,
    \\        ( a30 * b04 - a31 * b02 + a33 * b00) * inv_det,
    \\        (-a20 * b04 + a21 * b02 - a23 * b00) * inv_det,
    \\        (-a10 * b09 + a11 * b07 - a12 * b06) * inv_det,
    \\        ( a00 * b09 - a01 * b07 + a02 * b06) * inv_det,
    \\        (-a30 * b03 + a31 * b01 - a32 * b00) * inv_det,
    \\        ( a20 * b03 - a21 * b01 + a22 * b00) * inv_det);
    \\}
    \\
    \\
;

/// Square dimension (2/3/4) of a MatrixInverse result matrix type, or null if not a
/// supported square float matrix.
fn matrixInverseDim(m: *const ParsedModule, result_type_id: u32) ?u8 {
    const ti = getDef(m, result_type_id) orelse return null;
    if (ti.op != .TypeMatrix or ti.words.len < 4) return null;
    const cols = ti.words[3];
    const col_inst = getDef(m, ti.words[2]) orelse return null;
    if (col_inst.op != .TypeVector or col_inst.words.len < 4) return null;
    const rows = col_inst.words[3];
    if (cols != rows) return null;
    return switch (cols) {
        2, 3, 4 => @intCast(cols),
        else => null,
    };
}

const InverseDims = struct { n2: bool = false, n3: bool = false, n4: bool = false };

/// Scan the module for GLSL.std.450 MatrixInverse(34) ExtInsts and record which
/// helper dimensions are needed, so each is emitted at most once. Assumes the module's
/// only ExtInstImport is GLSL.std.450 (always true for zioshade-produced SPIR-V) — the
/// set id (words[3]) is not re-checked, matching the rest of the .ExtInst handling.
fn moduleInverseDims(m: *const ParsedModule) InverseDims {
    var r = InverseDims{};
    for (m.instructions) |inst| {
        if (inst.op == .ExtInst and inst.words.len >= 6 and inst.words[4] == 34) {
            if (matrixInverseDim(m, inst.words[1])) |d| switch (d) {
                2 => r.n2 = true,
                3 => r.n3 = true,
                4 => r.n4 = true,
                else => {},
            };
        }
    }
    return r;
}

/// The default-interpolation accessor appended to a pull-model `interpolant<>` input's
/// body alias so that PLAIN reads compile. The InterpolateAt* ExtInst arm strips this
/// EXACT suffix to recover the `in.<name>` base for its own method calls — the two sites
/// MUST use this single constant so they can never drift apart (a drift would turn a
/// valid pull-model shader into a false `error.UnsupportedOp` rejection).
const pull_model_center_suffix = ".interpolate_at_center()";

/// Scan the module for GLSL.std.450 InterpolateAtCentroid(76)/InterpolateAtSample(77)/
/// InterpolateAtOffset(78) ExtInsts and collect the id of each interpolant operand
/// (words[5], a pointer to the queried Input variable). These inputs must be declared
/// as `interpolant<T, interpolation::perspective>` in the stage-in struct and read via
/// method calls (Metal pull-model interpolation, MSL 2.3+). Returns a set of operand
/// ids; the caller is responsible for `deinit`. For the common case the operand is the
/// top-level Input OpVariable (which appears in `stage_inputs`); interface-block-member
/// or array interpolants (operand = an OpAccessChain result, not a stage-input var) are
/// caught downstream and honest-errored rather than silently mis-emitted.
fn collectPullModelInputs(m: *const ParsedModule, alloc: std.mem.Allocator) !std.AutoHashMap(u32, void) {
    var set = std.AutoHashMap(u32, void).init(alloc);
    for (m.instructions) |inst| {
        if (inst.op == .ExtInst and inst.words.len >= 6) {
            const ext = inst.words[4];
            if (ext == 76 or ext == 77 or ext == 78) try set.put(inst.words[5], {});
        }
    }
    return set;
}

/// Collect the storage-IMAGE variable ids that back an image atomic. Metal has no
/// native read-write atomic on a `texture2d`, so spirv-cross emulates them with a
/// buffer-backed linear texture: each such image needs a SEPARATE `device atomic_T*`
/// backing buffer and the `spvImage2DAtomicCoord` linearization macro. SPIR-V routes
/// image atomics through `OpImageTexelPointer` (whose Image operand, words[3], is the
/// image variable), so collecting every ImageTexelPointer's image var-id yields exactly
/// the atomic-accessed images (ImageTexelPointer exists only to feed OpAtomic*).
fn collectAtomicImages(m: *const ParsedModule, alloc: std.mem.Allocator) !std.AutoHashMap(u32, void) {
    var set = std.AutoHashMap(u32, void).init(alloc);
    for (m.instructions) |inst| {
        if (inst.op == .ImageTexelPointer and inst.words.len >= 4) try set.put(inst.words[3], {});
    }
    return set;
}

const ImageAccess = struct { read: bool = false, write: bool = false };

/// Map each storage-image variable id to whether it is actually READ (OpImageRead)
/// and/or WRITTEN (OpImageWrite). Used to pick the MSL `access::` qualifier, matching
/// spirv-cross: read+write → read_write, write-only → write, read-only or atomic-only
/// (neither OpImageRead nor OpImageWrite — the atomic goes through the backing buffer)
/// → no qualifier (default sample access, which still supports `.read()`). The image
/// operand of OpImageRead/Write is an OpLoad of the image variable, so a load→var map
/// resolves it back to the UniformConstant variable.
fn collectImageAccess(m: *const ParsedModule, alloc: std.mem.Allocator) !std.AutoHashMap(u32, ImageAccess) {
    var map = std.AutoHashMap(u32, ImageAccess).init(alloc);
    var load_to_var = std.AutoHashMap(u32, u32).init(alloc);
    defer load_to_var.deinit();
    for (m.instructions) |inst| {
        if (inst.op == .Load and inst.words.len >= 4) {
            const pd = getDef(m, inst.words[3]) orelse continue;
            if (pd.op == .Variable and pd.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(pd.words[3]);
                if (sc == .UniformConstant) try load_to_var.put(inst.words[2], inst.words[3]);
            }
        }
    }
    for (m.instructions) |inst| {
        if (inst.op == .ImageRead and inst.words.len >= 4) {
            if (load_to_var.get(inst.words[3])) |vid| {
                const e = try map.getOrPutValue(vid, .{});
                e.value_ptr.read = true;
            }
        } else if (inst.op == .ImageWrite and inst.words.len >= 4) { // image, coord, texel
            if (load_to_var.get(inst.words[1])) |vid| {
                const e = try map.getOrPutValue(vid, .{});
                e.value_ptr.write = true;
            }
        }
    }
    return map;
}

/// The MSL `access::` suffix (including the leading `, `) for a storage image with the
/// given actual read/write usage. read+write → `, access::read_write`; write-only →
/// `, access::write`; read-only / unused → `` (default sample access supports `.read()`).
fn mslStorageAccessSuffix(acc: ImageAccess) []const u8 {
    if (acc.read and acc.write) return ", access::read_write";
    if (acc.write) return ", access::write";
    return "";
}

/// True if any OpImageTexelPointer (image atomic) lives in a NON-entry function. The
/// emulation binds the `device atomic_T*` backing buffer only in the entry-point
/// signature, so a non-entry helper performing an image atomic would reference an
/// undeclared `<img>_atomic` (silent-wrong). zioshade's own frontend inlines all user
/// functions into the entry, so this only arises for externally-supplied, non-inlined
/// SPIR-V — honest-error it. (Image atomics whose operand is a function PARAMETER are
/// already rejected by mslAtomicImageScalar's `op != .Variable` check.)
fn imageAtomicInNonEntryFn(m: *const ParsedModule, entry_id: u32) bool {
    var current_func: u32 = 0;
    for (m.instructions) |inst| {
        if (inst.op == .Function and inst.words.len > 2) {
            current_func = inst.words[2];
        } else if (inst.op == .ImageTexelPointer and current_func != entry_id) {
            return true;
        }
    }
    return false;
}

/// The buffer-backed linear-texture atomic emulation preamble (alignment
/// function-constant + the 2D coord-linearization macro), reproduced from
/// `spirv-cross --msl`. Emitted once when the module contains image atomics.
const spv_image2d_atomic_template =
    \\#include <metal_atomic>
    \\constant uint spvLinearTextureAlignmentOverride [[function_constant(65535)]];
    \\constant uint spvLinearTextureAlignment = is_function_constant_defined(spvLinearTextureAlignmentOverride) ? spvLinearTextureAlignmentOverride : 4;
    \\#define spvImage2DAtomicCoord(tc, tex) (((((tex).get_width() + spvLinearTextureAlignment / 4 - 1) & ~(spvLinearTextureAlignment / 4 - 1)) * (tc).y) + (tc).x)
    \\
    \\
;

/// The exact `spvUnsafeArray<T, Num>` template emitted by `spirv-cross --msl`
/// (reproduced verbatim so zioshade output is structurally equivalent).
const spv_unsafe_array_template =
    \\template<typename T, size_t Num>
    \\struct spvUnsafeArray
    \\{
    \\    T elements[Num ? Num : 1];
    \\
    \\    thread T& operator [] (size_t pos) thread
    \\    {
    \\        return elements[pos];
    \\    }
    \\    constexpr const thread T& operator [] (size_t pos) const thread
    \\    {
    \\        return elements[pos];
    \\    }
    \\
    \\    device T& operator [] (size_t pos) device
    \\    {
    \\        return elements[pos];
    \\    }
    \\    constexpr const device T& operator [] (size_t pos) const device
    \\    {
    \\        return elements[pos];
    \\    }
    \\
    \\    constexpr const constant T& operator [] (size_t pos) const constant
    \\    {
    \\        return elements[pos];
    \\    }
    \\
    \\    threadgroup T& operator [] (size_t pos) threadgroup
    \\    {
    \\        return elements[pos];
    \\    }
    \\    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    \\    {
    \\        return elements[pos];
    \\    }
    \\};
    \\
    \\
;

fn constantLiteral(alloc: std.mem.Allocator, type_inst: Instruction, literal_words: []const u32) ![]const u8 {
    // #476: width-aware — honest-error 64-bit (2-word truncation) and 16-bit float (low-
    // bits mis-bitcast); sign-extend signed int16. See spirv_to_glsl.zig for the rationale.
    if (type_inst.op == .TypeFloat and type_inst.words.len > 2) {
        const w = type_inst.words[2];
        if (w == 64) return error.UnsupportedConstantWidth;
        if (w == 16 and literal_words.len > 0) {
            const h: f16 = @bitCast(@as(u16, @truncate(literal_words[0])));
            const val: f32 = @floatCast(h);
            if (val == @floor(val)) {
                const ival: i32 = @intFromFloat(val);
                return std.fmt.allocPrint(alloc, "{d}.0", .{ival});
            }
            return std.fmt.allocPrint(alloc, "{d}", .{val});
        }
    } else if (type_inst.op == .TypeInt and type_inst.words.len > 2) {
        const w = type_inst.words[2];
        if (w == 64) return error.UnsupportedConstantWidth;
        if (w == 16 and type_inst.words.len > 3 and type_inst.words[3] != 0 and literal_words.len > 0) {
            const v: i16 = @bitCast(@as(u16, @truncate(literal_words[0])));
            return std.fmt.allocPrint(alloc, "{d}", .{v});
        }
    }
    if (type_inst.op == .TypeFloat and literal_words.len > 0) {
        const val: f32 = @bitCast(literal_words[0]);
        if (val == @floor(val) and @abs(val) < 1e6) {
            const ival: i32 = @intFromFloat(val);
            return std.fmt.allocPrint(alloc, "{d}.0", .{ival});
        }
        return std.fmt.allocPrint(alloc, "{d}", .{val});
    }
    if (type_inst.op == .TypeInt and literal_words.len > 0) {
        const signed = type_inst.words.len > 3 and type_inst.words[3] != 0;
        if (signed) {
            const val: i32 = @bitCast(literal_words[0]);
            return std.fmt.allocPrint(alloc, "{d}", .{val});
        } else return std.fmt.allocPrint(alloc, "{d}u", .{literal_words[0]});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{literal_words[0]});
}

/// Classification of a Function-storage array `OpVariable` initialized by a
/// single whole-variable `OpStore` of a constant.
const LocalConstArray = struct {
    /// The initializer `OpConstant`/`OpConstantComposite` id.
    init_id: u32,
    /// true → the variable is also partially written (e.g. `a[1].z = …`) or
    /// escapes by pointer, so it must stay a mutable local (the initializer is
    /// folded into the declaration as a brace initializer). false → the variable
    /// is read-only and is promoted to a module-scope `constant`.
    mutated: bool,
};

/// Follow a pointer id through any chain of `OpAccessChain`/`OpCopyObject`
/// down to its root and report whether that root is `var_id`. Used to detect a
/// partial write to (or pointer escape of) a variable even when the store goes
/// through a *nested* access chain — `mergeAccessChains` flattens most nested
/// chains, but skips an intermediate chain that has a non-AccessChain user
/// (e.g. a whole-element Load), which would otherwise hide the mutation.
fn pointerRootsAt(m: *const ParsedModule, start_id: u32, var_id: u32) bool {
    var id = start_id;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        if (id == var_id) return true;
        const inst = getDef(m, id) orelse return false;
        switch (inst.op) {
            .AccessChain, .CopyObject => {
                if (inst.words.len < 4) return false;
                id = inst.words[3];
            },
            else => return false,
        }
    }
    return false;
}

/// Classify a Function array `OpVariable` that is initialized by exactly one
/// whole-variable `OpStore` of a `Constant`/`ConstantComposite`. Returns null
/// for anything else (not a Function array var, multiple whole stores, or a
/// whole store of a non-constant). A whole-array copy assignment `a = vC;` is
/// invalid in Metal (C arrays are not assignable), so the backend must NOT emit
/// the init store verbatim — it either promotes the variable to a module-scope
/// `constant` (read-only) or brace-initializes it in place (mutated).
fn analyzeLocalConstArray(m: *const ParsedModule, var_inst: Instruction) ?LocalConstArray {
    if (var_inst.op != .Variable or var_inst.words.len < 4) return null;
    const sc: spirv.StorageClass = @enumFromInt(var_inst.words[3]);
    if (sc != .Function) return null;
    const ptr = getDef(m, var_inst.words[1]) orelse return null;
    if (ptr.op != .TypePointer or ptr.words.len < 4) return null;
    const pointee = getDef(m, ptr.words[3]) orelse return null;
    if (pointee.op != .TypeArray) return null;
    const var_id = var_inst.words[2];

    var init_id: ?u32 = null;
    var whole_stores: u32 = 0;
    var mutated = false;
    for (m.instructions) |inst| {
        switch (inst.op) {
            .Store => {
                if (inst.words.len < 3) continue;
                const dst = inst.words[1];
                if (dst == var_id) {
                    whole_stores += 1;
                    const val = getDef(m, inst.words[2]) orelse return null;
                    switch (val.op) {
                        .Constant, .ConstantComposite, .ConstantTrue, .ConstantFalse => init_id = inst.words[2],
                        else => return null, // whole store of a non-constant → not ours
                    }
                } else if (pointerRootsAt(m, dst, var_id)) {
                    // A store through a (possibly nested) access chain rooted at
                    // the variable is a partial write → the variable is mutated.
                    mutated = true;
                }
            },
            // The variable escaping by pointer (passed to a function, or a
            // CopyMemory target) could mutate it; conservatively keep it a
            // mutable local rather than promoting.
            .FunctionCall => {
                if (inst.words.len > 4) for (inst.words[4..]) |a| {
                    if (a == var_id) mutated = true;
                };
            },
            .CopyMemory => {
                if (inst.words.len >= 2 and inst.words[1] == var_id) mutated = true;
            },
            else => {},
        }
    }
    if (whole_stores != 1) return null;
    const iid = init_id orelse return null;
    return .{ .init_id = iid, .mutated = mutated };
}

/// Write an array/struct constant's brace initializer, recursively inlining
/// nested array/struct composites (`{ { … }, { … } }`). Scalar constants and
/// vector composites use their precomputed name (`"10.0"`, `"float4(0.0)"`).
fn writeMslConstInit(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), w: anytype, id: u32, alloc: std.mem.Allocator) !void {
    const inst = getDef(m, id) orelse {
        try w.writeAll(names.get(id) orelse "0");
        return;
    };
    if (inst.op == .ConstantComposite and inst.words.len > 3) {
        if (getDef(m, inst.words[1])) |t| {
            if (t.op == .TypeArray or t.op == .TypeStruct) {
                try w.writeAll("{ ");
                for (inst.words[3..], 0..) |cid, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeMslConstInit(m, names, w, cid, alloc);
                }
                try w.writeAll(" }");
                return;
            }
            // Matrix / vector composites must be INLINED with a typed
            // constructor — e.g. `float4x4(float4(…), …)` — because their nested
            // constituents are constant_composites that are NOT emitted at module
            // scope (referencing them by name would be an undefined identifier).
            // (#173 item1: matrix-element const arrays.)
            if (t.op == .TypeMatrix or t.op == .TypeVector) {
                const ty_str = mslType(m, inst.words[1], names, alloc) catch null;
                if (ty_str) |ts| {
                    try w.print("{s}(", .{ts});
                    for (inst.words[3..], 0..) |cid, i| {
                        if (i > 0) try w.writeAll(", ");
                        try writeMslConstInit(m, names, w, cid, alloc);
                    }
                    try w.writeAll(")");
                    return;
                }
            }
        }
    }
    try w.writeAll(names.get(id) orelse "0");
}

fn getDecVal(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) ?u32 {
    const list = decs.get(id) orelse return null;
    for (list.items) |e| {
        if (e.decoration == dec and e.extra.len > 0) return e.extra[0];
    }
    return null;
}

fn hasDec(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) bool {
    const list = decs.get(id) orelse return false;
    for (list.items) |e| {
        if (e.decoration == dec) return true;
    }
    return false;
}

// OpMemberDecorate value reader (struct_id, member_index): an interface-block
// member's explicit Location, when present. (#478)
fn memberDecVal(m: *const ParsedModule, struct_id: u32, member: u32, dec: spirv.Decoration) ?u32 {
    for (m.instructions) |inst| {
        if (inst.op == .MemberDecorate and inst.words.len >= 5 and
            inst.words[1] == struct_id and inst.words[2] == member and
            inst.words[3] == @intFromEnum(dec)) return inst.words[4];
    }
    return null;
}

/// True if member `member` of `struct_id` carries `dec` (works for VALUE-LESS
/// MemberDecorate like Flat/NoPerspective, which memberDecVal -- requiring a value
/// word -- cannot detect). (#475)
fn memberHasDec(m: *const ParsedModule, struct_id: u32, member: u32, dec: spirv.Decoration) bool {
    for (m.instructions) |inst| {
        if (inst.op != .MemberDecorate or inst.words.len < 4) continue;
        if (inst.words[1] == struct_id and inst.words[2] == member and
            inst.words[3] == @intFromEnum(dec)) return true;
    }
    return false;
}

/// True if `type_id` (or its scalar element, through vector/array/matrix) is an integer.
/// Used to OMIT `[[flat]]` for integer varyings: Metal AUTO-FLATS integers, so the
/// (redundant) Flat decoration glslang emits on them must be dropped to match spirv-cross
/// (#475 — re-trips the prior T15.5 trap if not).
fn mslElementIsInt(m: *const ParsedModule, type_id: u32) bool {
    const inst = getDef(m, type_id) orelse return false;
    return switch (inst.op) {
        .TypeInt => true,
        .TypeVector, .TypeArray, .TypeMatrix => if (inst.words.len > 2) mslElementIsInt(m, inst.words[2]) else false,
        else => false,
    };
}

/// Append `set` to `list` only if it's not already present. Used to gather
/// the unique set indices in use by an argument-buffer-mode entry point.
fn addUniqueSet(list: *std.ArrayList(u32), set: u32, alloc: std.mem.Allocator) !void {
    for (list.items) |existing| {
        if (existing == set) return;
    }
    try list.append(alloc, set);
}

// ---- Public API ----
/// Options for SPIR-V → MSL cross-compilation.
/// Explicit per-resource MSL slot override (descriptor remap, G6). Maps a SPIR-V
/// (descriptor set, binding) to an explicit MSL attribute index — `[[buffer(N)]]`
/// / `[[texture(N)]]` / `[[sampler(N)]]` (the attribute kind is inferred from the
/// resource type). Takes precedence over `binding_shift`. Mirrors spirv-cross's
/// `add_msl_resource_binding` for the common (legacy, non-argument-buffer) path.
pub const MslResourceBinding = struct {
    set: u32 = 0,
    binding: u32,
    msl_slot: u32,
};

pub const MslCompileOptions = struct {
    /// Target Metal version (21 = Metal 2.1, 30 = Metal 3.0).
    metal_version: u32 = 21,
    /// Entry point name to compile (default: "main").
    entry_point_name: []const u8 = "main",
    /// Per-resource MSL slot overrides (checked before `binding_shift`).
    resource_bindings: []const MslResourceBinding = &.{},
    /// Shift all descriptor bindings by this amount. -1 remaps binding=1 → [[buffer(0)]].
    /// Applied uniformly to [[buffer]], [[texture]], and [[sampler]] slot indices
    /// (their indices are separate namespaces, but zioshade's convention — matching
    /// HLSL — is one shift across all kinds). Negative results clamp to 0.
    binding_shift: i32 = 0,
    /// When true, group descriptor-set resources into `spvDescriptorSetBufferN`
    /// structs and pass each set as a single [[buffer(N)]] argument-buffer
    /// parameter. Matches the Metal 2+ idiom and SPIRV-Cross's
    /// `--msl-argument-buffers` output. Default: false (legacy per-resource binding).
    ///
    /// v1 scope (M6): set 0 only; UBO + sampled-image (split into texture +
    /// sampler [[id]] slots); fragment + compute entry points. Multiple sets
    /// and storage buffers are deferred to M6 v2. `binding_shift` still applies
    /// to the single `[[buffer(N)]]` of each argument buffer; it does NOT apply
    /// to the `[[id]]` slots inside the struct.
    argument_buffers: bool = false,
};

/// Resolve the MSL attribute slot for a resource at (set, binding): an explicit
/// `resource_bindings` override wins, otherwise fall back to the binding-shifted
/// value (legacy per-resource path).
fn resolveMslSlot(bindings: []const MslResourceBinding, binding_shift: i32, set: u32, binding: u32) u32 {
    for (bindings) |rb| {
        if (rb.set == set and rb.binding == binding) return rb.msl_slot;
    }
    return common.applyBindingShift(binding, binding_shift);
}

pub fn spirvToMSL(alloc: std.mem.Allocator, spirv_words: []const u32, options: MslCompileOptions) ![]const u8 {
    // Honest-error: PhysicalStorageBufferAddresses (buffer_reference / physical pointers)
    // is not lowered by the MSL backend — Metal has no physical-pointer equivalent in
    // this context. Honest-error rather than emit invalid output. (#170)
    {
        var ci: usize = 5; // skip 5-word SPIR-V header
        while (ci + 1 < spirv_words.len) {
            const wc = spirv_words[ci] >> 16;
            if (wc == 0) break;
            if ((spirv_words[ci] & 0xFFFF) == 17) {
                const cap = spirv_words[ci + 1];
                if (cap == 5347) return error.UnsupportedPhysicalStorageBuffer;
                if (cap == 4428 or cap == 4439 or cap == 4437) return error.UnsupportedExtensionCapability;
            }
            ci += wc;
        }
    }
    // G2: recover OpSelectionMerge for unstructured-but-reducible SPIR-V (no-op on
    // structured input; fall back to the original on failure — see spirvToGLSL).
    const _norm = @import("cfg_structurize.zig").structurizeModule(alloc, spirv_words) catch null;
    defer if (_norm) |n| alloc.free(n);
    var module = try parseModule(alloc, _norm orelse spirv_words);
    defer module.deinit(alloc);

    // Descriptor sampler/image ARRAYS not yet supported by the MSL backend — fail
    // loud rather than emit broken output (the GLSL backend supports them).
    // MSL keeps its existing behavior: honest-error only the bounded `tex[N]` opaque
    // array (include_runtime = false); the unbounded form is handled elsewhere. (#170)
    if (common.hasOpaqueArrayResource(&module, false)) return error.UnsupportedSamplerArray;
    // #476: honest-error 64-bit numeric types (32-bit target; silent truncation otherwise).
    switch (common.wide64Type(module.instructions)) {
        .float64 => return error.UnsupportedDoubleType,
        .int64 => return error.UnsupportedInt64Type,
        .none => {},
    }

    // Override entry point if requested
    if (!std.mem.eql(u8, options.entry_point_name, "main")) {
        if (findEntryPoint(&module, options.entry_point_name)) |ep_id| {
            module.entry_point_id = ep_id;
        } else return error.EntryPointNotFound;
    }

    // Metal ray tracing uses a fundamentally different model (compute + intersection queries)
    // Vulkan's ray tracing pipeline stages cannot be directly mapped
    if (module.execution_model == .RayGenerationKHR or module.execution_model == .ClosestHitKHR or
        module.execution_model == .MissKHR or module.execution_model == .IntersectionKHR or
        module.execution_model == .AnyHitKHR or module.execution_model == .CallableKHR)
    {
        return error.CrossCompileUnsupported;
    }

    const entry_id = module.entry_point_id orelse return error.NoEntryPoint;

    // Reject row_major matrix layouts we cannot emit correctly (non-square, any
    // struct depth) before emitting anything — honest error over silent-wrong.
    try checkUnsupportedRowMajor(&module);

    // Reject GLSL features with no valid MSL form (e.g. fragment barycentrics)
    // before emitting anything: honest "unsupported" error over silent-wrong MSL.
    try checkUnsupportedMslFeatures(&module);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var names = std.AutoHashMap(u32, []const u8).init(aa);
    defer names.deinit();
    var decs = std.AutoHashMap(u32, std.ArrayList(DecorationEntry)).init(aa);
    defer decs.deinit();

    collectNames(aa, &module, &names);
    // Prewrite unique struct names BEFORE any forward-decl emission so two
    // distinct structs sharing one OpName don't collapse (the common forward-decl
    // emitter dedups by name and would drop the second's real layout -> uses bind
    // the wrong bytes, #zm0 / #cgv). MSL's struct emitter delegates to the common
    // helper, so -- like GLSL/HLSL -- it just needs this pre-pass call.
    common.commonPrewriteUniqueStructNames(module.instructions, &names, aa, common.commonPassthroughName);
    try collectDecorations(aa, &module, &decs);

    // Honest-error: a plain (non-Block, non-builtin) STRUCT vertex output isn't flattened
    // by the MSL backend (#500 covers fragment INPUTS, not vertex outputs) — the body's
    // write would reference an undeclared identifier (plausible-but-wrong). gl_PerVertex
    // (Block-decorated) is handled by #471. (#170)
    if (module.execution_model == .Vertex) {
        for (module.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Output) continue;
            const vid = inst.words[2];
            if (getDecVal(&decs, vid, .built_in) != null) continue;
            const ptr_def = getDef(&module, inst.words[1]) orelse continue;
            if (ptr_def.op != .TypePointer or ptr_def.words.len < 4) continue;
            const pt = ptr_def.words[3];
            const struct_def = getDef(&module, pt) orelse continue;
            if (struct_def.op == .TypeStruct and !hasDec(&decs, pt, .block)) {
                return error.UnsupportedStructStageOutput;
            }
        }
    }
    // Honest-error: clip/cull distance as a vertex OUTPUT builtin isn't promoted by #471
    // for the direct-Output-variable form. (#170)
    if (module.execution_model == .Vertex) {
        for (module.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Output) continue;
            if (getDecVal(&decs, inst.words[2], .built_in)) |bi| {
                const ebi: spirv.BuiltIn = @enumFromInt(bi);
                if (ebi == .clip_distance or ebi == .cull_distance) {
                    return error.UnsupportedBuiltinStageOutput;
                }
            }
        }
    }

    // Promote read-only const arrays so a runtime index resolves to a declared
    // module-scope `constant` (emitted below): alias each const-initialized
    // Private global (Design A) AND each read-only function-local const array to
    // its initializer constant's name. Metal cannot copy a C array (`a = vC;`),
    // so promotion (or in-place brace init for mutated locals) is mandatory —
    // otherwise the index reads an undeclared identifier (silent-wrong).
    common.aliasConstInitializedPrivateVars(aa, &module, &names);
    // Mangle function-scope ids (Function-class OpVariable or OpFunctionParameter)
    // whose name collides with a GLOBAL OpVariable's -- the only collision that
    // silently shadows (#sid / #cuj). Scope-aware + block-instance-excluded (MSL
    // also block-names UBO instances as Globals_1, so the exclusion fits). Without
    // this, two same-named ids (e.g. a Private global + a function-local both
    // "a_b") emit a redefinition (invalid MSL). Runs after aliasConst.
    common.commonPrewriteUniqueLocalVarNames(module.instructions, &names, aa, true);
    for (module.instructions) |inst| {
        if (inst.op != .Variable) continue;
        const info = analyzeLocalConstArray(&module, inst) orelse continue;
        if (info.mutated) continue;
        const cname = names.get(info.init_id) orelse continue;
        const dup = aa.dupe(u8, cname) catch continue;
        if (names.fetchPut(inst.words[2], dup) catch null) |old| aa.free(old.value);
    }

    // C8 (honest-error): a Private array global with NO initializer that the
    // backend never declares would leak into the body as an UNDEFINED identifier
    // (`float4x4 vN = M[i];` with no `M`). This happens for matrix-element const
    // arrays (`const mat4 M[N]`), which the FRONTEND does not fold to an
    // OpConstantComposite (float/vec ARE folded). Rather than emit a reference to
    // an undeclared name (silent-wrong), fail loud until the frontend folds them
    // (deferred to a frontend fix -- see zioshade/zioshade#173). Detect: a Private OpVariable whose
    // unwrapped pointee is an array, with no initializer operand and no recovered
    // const initializer, that is actually referenced by the body.
    for (module.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .Private) continue;
        if (inst.words.len >= 5) continue; // has an OpVariable initializer operand
        if (common.constInitializedPrivateVar(&module, inst) != null) continue; // recovered const init
        const ptr = getDef(&module, inst.words[1]) orelse continue;
        if (ptr.op != .TypePointer or ptr.words.len < 4) continue;
        var pointee = getDef(&module, ptr.words[3]) orelse continue;
        while (pointee.op == .TypeArray and pointee.words.len > 2) {
            pointee = getDef(&module, pointee.words[2]) orelse break;
        }
        // Only the array shape is the unsupported case here (the frontend gap).
        const pe0 = getDef(&module, ptr.words[3]) orelse continue;
        if (pe0.op != .TypeArray) continue;
        const var_id = inst.words[2];
        // Confirm the variable is actually referenced (loaded or access-chained)
        // so a dead global never trips the error.
        var referenced = false;
        for (module.instructions) |use| {
            switch (use.op) {
                .AccessChain, .Load, .CopyObject => {
                    if (use.words.len >= 4 and pointerRootsAt(&module, use.words[3], var_id)) referenced = true;
                },
                else => {},
            }
            if (referenced) break;
        }
        // Admitted by the threading path only when MUTATED, WITHOUT an
        // initializer operand, AND the length resolves to a plain OpConstant
        // (mslValueType refuses anything else -- a spec-const length -- and the
        // collector's catch-continue would then drop the variable SILENTLY while
        // this refusal stays suppressed: rc=0 on undeclared-identifier MSL,
        // found by review). Anything unadmitted keeps the honest error.
        var mutated_arr = false;
        for (module.instructions) |su| {
            if (su.op == .Store and su.words.len >= 3 and pointerRootsAt(&module, su.words[1], var_id)) {
                mutated_arr = true;
                break;
            }
        }
        const len_resolvable = blk: {
            const len_def = getDef(&module, pe0.words[3]) orelse break :blk false;
            break :blk len_def.op == .Constant and len_def.words.len > 3;
        };
        if (referenced and !(mutated_arr and inst.words.len < 5 and len_resolvable)) return error.UndeclaredPrivateArrayGlobal;
    }

    var member_offsets = std.AutoHashMap(MemberKey, u32).init(aa);
    defer member_offsets.deinit();
    collectMemberOffsets(&module, &member_offsets);

    var cbuffers = std.ArrayList(CbufferDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer cbuffers.deinit(aa);
    var loose_uniforms = std.ArrayList(LooseUniform).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer loose_uniforms.deinit(aa);
    var textures = std.ArrayList(TextureDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer textures.deinit(aa);
    // Per-storage-image read/write usage → picks the MSL access:: qualifier.
    var img_access = try collectImageAccess(&module, aa);
    defer img_access.deinit();
    // Storage-image atomics: image var-ids backed by a `device atomic_T*` buffer.
    // Collected so collectResources + emitFunction know to bind the backing buffer
    // alongside the texture. The texture itself takes an access:: qualifier from its
    // actual OpImageRead/OpImageWrite usage (img_access) — Metal's get_width() (used
    // by spvImage2DAtomicCoord) is valid on any access qualifier, so a written atomic
    // image correctly takes access::write; a coord-only one stays default (sample).
    var atomic_images = try collectAtomicImages(&module, aa);
    defer atomic_images.deinit();
    // #493: depth-from-usage -- MUST run before collectResources so depth-typed-from-
    // usage textures (Depth=0 but used in a depth OpSampledImage, e.g. GL_EXT samplerless
    // `sampler2DShadow(texture2D, samplerShadow)`) are typed depth2d for sample_compare.
    var depth_tex_types = std.AutoHashMap(u32, void).init(aa);
    defer depth_tex_types.deinit();
    g_depth_tex_types = &depth_tex_types;
    defer g_depth_tex_types = null;
    for (module.instructions) |inst| {
        if (inst.op != .SampledImage or inst.words.len < 5) continue;
        const rt = getDef(&module, inst.words[1]) orelse continue;
        if (rt.op != .TypeSampledImage or rt.words.len < 3) continue;
        const di = getDef(&module, rt.words[2]) orelse continue;
        if (di.op != .TypeImage or di.words.len <= 4) continue;
        if (di.words[4] != 1) continue; // result is not a depth sampled image
        const img_op = getDef(&module, inst.words[3]) orelse continue;
        if (img_op.words.len < 2) continue;
        depth_tex_types.put(img_op.words[1], {}) catch {};
    }
    collectResources(&module, &names, &decs, &cbuffers, &textures, &loose_uniforms, &img_access, aa);

    // Stage inputs (layout(location) in ...). Collected with their ORIGINAL
    // names BEFORE any body-emit rename, so the `main0_in` struct fields use
    // the source name while body references are rewritten to `in.<name>` later.
    // Collected for fragment ([[user(locnN)]]) and vertex ([[attribute(N)]]);
    // the attribute spelling is gated at emit time.
    var stage_inputs = std.ArrayList(StageInputDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer stage_inputs.deinit(aa);
    // (block_var<<20 | member) -> flattened main0_in field name, for the
    // buildAccessExpr interface-block rewrite (#478).
    var block_flat = std.AutoHashMap(u64, []const u8).init(aa);
    if (module.execution_model == .Fragment or module.execution_model == .Vertex) {
        collectStageInputs(&module, &names, &decs, &stage_inputs, &block_flat, aa);
    }
    g_block_flat = &block_flat;
    defer g_block_flat = null;

    var sampled_sampler = std.AutoHashMap(u32, []const u8).init(aa);
    defer sampled_sampler.deinit();
    g_sampled_sampler = &sampled_sampler;
    defer g_sampled_sampler = null;

    // #481: gl_SampleMaskIn is an int[] in GLSL but [[sample_mask]] is a scalar
    // uint in Metal; record its var so writeAccessExprPlain drops the `[0]` index.
    // #472: also record an OUTPUT gl_SampleMask — it is int[1] in SPIR-V but a scalar
    // uint [[sample_mask]] in Metal, so the body's `gl_SampleMask[0] = x` write must
    // drop the `[0]` index too.
    var scalar_builtins = std.AutoHashMap(u32, void).init(aa);
    for (module.instructions) |sbi| {
        if (sbi.op != .Variable or sbi.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(sbi.words[3]);
        if (sc != .Input and sc != .Output) continue;
        if (builtinOf(&decs, sbi.words[2])) |bi| {
            if (bi == @intFromEnum(spirv.BuiltIn.sample_mask)) scalar_builtins.put(sbi.words[2], {}) catch {};
        }
    }
    g_scalar_builtin_vars = &scalar_builtins;
    defer g_scalar_builtin_vars = null;

    // #472: gl_SamplePosition has NO Metal [[attribute]] (spirv-cross computes it
    // from sample positions). It is a fragment INPUT builtin used by exactly one
    // corpus shader (sample-parameter.frag); honest-error that niche case rather
    // than emit a body that uses an undeclared identifier. This deliberately does
    // NOT touch gl_SampleID ([[sample_id]]): input-attachment-ms.vk.frag uses
    // gl_SampleID but its subpassLoad lowering ignores the sample id, so it never
    // reaches this declaration path and stays valid.
    if (module.execution_model == .Fragment) {
        for (module.instructions) |sbi| {
            if (sbi.op != .Variable or sbi.words.len < 4) continue;
            const sc: spirv.StorageClass = @enumFromInt(sbi.words[3]);
            if (sc != .Input) continue;
            if (builtinOf(&decs, sbi.words[2])) |bi| {
                if (bi == @intFromEnum(spirv.BuiltIn.sample_position)) return error.UnsupportedSamplePosition;
            }
        }
    }

    // Pull-model interpolation: the set of Input variable ids queried by
    // interpolateAtCentroid/Sample/Offset. Those inputs are declared
    // `interpolant<T, interpolation::perspective>` and read via method calls.
    var pull_model = try collectPullModelInputs(&module, aa);
    defer pull_model.deinit();

    // Vertex stage outputs (layout(location) out ... + gl_Position). Collected
    // with ORIGINAL names so `main0_out` fields use the source name while body
    // stores are rewritten to `out.<name>` (incl. `out.gl_Position`) later.
    var stage_outputs = std.ArrayList(StageOutputDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer stage_outputs.deinit(aa);
    if (module.execution_model == .Vertex) {
        collectStageOutputs(&module, &names, &decs, &stage_outputs, aa);
    }

    var output = std.ArrayList(u8).initCapacity(alloc, 4096) catch return error.OutOfMemory;
    var output_owned = true;
    defer if (output_owned) output.deinit(alloc);
    const w = compat.listWriter(&output, alloc);

    const is_compute = module.execution_model == .GLCompute;
    const is_mesh = module.execution_model == .MeshEXT;
    const is_task = module.execution_model == .TaskEXT;
    const is_compute_like = is_compute or is_mesh or is_task;
    const is_frag = module.execution_model == .Fragment;
    const is_vertex = module.execution_model == .Vertex;

    // #472: fragment outputs (color/MRT/dual-source + FragDepth/SampleMask/stencil).
    // Collected with ORIGINAL names so `main0_out` fields + body routing match. When
    // the set is NOT the single-color common case, the multi-field main0_out path is
    // taken (g_frag_outputs); otherwise the legacy hardcoded path stays byte-identical.
    var frag_outputs = std.ArrayList(FragOutput).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer frag_outputs.deinit(aa);
    if (is_frag) {
        collectFragmentOutputs(&module, &names, &decs, &frag_outputs, aa);
    }
    const frag_multi = is_frag and !isSingleColorFragOutput(frag_outputs.items);
    if (frag_multi) {
        // Order outputs for main0_out: colors ascending by Location, then the builtin
        // kinds after (spirv-cross emits colors by location; builtin field order does
        // not affect Metal validity).
        const SortCtx = struct {
            fn rank(o: FragOutput) u32 {
                return switch (o.kind) {
                    .color => o.location,
                    .frag_depth => 1_000_000,
                    .sample_mask => 1_000_001,
                    .stencil_ref => 1_000_002,
                };
            }
            fn lessThan(_: void, a: FragOutput, b: FragOutput) bool {
                return rank(a) < rank(b);
            }
        };
        std.sort.insertion(FragOutput, frag_outputs.items, {}, SortCtx.lessThan);
        g_frag_outputs = frag_outputs.items;
    }
    defer g_frag_outputs = null;

    // MSL header
    try w.writeAll("#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n");

    // Whole-array value semantics: Metal C-arrays are not assignable, so any
    // array used as a VALUE (whole OpLoad/OpStore/OpCopyObject, array-typed
    // param/return) must use the `spvUnsafeArray<T,N>` template (the spirv-cross
    // idiom). Emit the template once, gated on actual need. Read-only const
    // arrays that are only INDEXED keep the simpler valid `constant T[N]` path
    // (intentional divergence from spirv-cross — see the module-array block).
    // textureQueryLod (OpImageQueryLod) lowers to calculate_clamped_lod /
    // calculate_unclamped_lod, which exist only on MSL 2.2+. These ARE Metal-
    // representable, so emit the lowering unconditionally (the runtime accepts it —
    // MslCompileCheck compiles with the device's latest language version, and Metal 2.2
    // ships on all modern macOS). spirv-cross makes this opt-in via --msl-version 22;
    // zioshade auto-bumps by emitting the lowering rather than honest-erroring. The
    // ImageQueryLod arm (emitBody) is therefore reached for every shader.

    // Pull-model interpolation (interpolant<> + .interpolate_at_*() methods) is an
    // MSL 2.3+ feature. Below 2.3, honest-error rather than emit non-compiling MSL —
    // matching spirv-cross, which throws "Pull-model interpolation requires MSL 2.3."
    if (options.metal_version < 23 and pull_model.count() > 0) return error.UnsupportedOp;

    // Storage-image atomics → buffer-backed linear-texture emulation (spirv-cross's
    // spvImage2DAtomicCoord scheme). Implemented for the COMPUTE and FRAGMENT paths.
    // Honest-error the cases this slice does not cover, rather than emit the old
    // non-compiling `&img[coord]`:
    //   - argument-buffer layout for the backing buffer (out of scope);
    //   - vertex/mesh/task image atomics (would need impl-helper backing-buffer threading);
    //   - non-2D / arrayed / float-component images (need 2D-array/3D macros or atomic_float).
    // Fragment works because imageAtomicInNonEntryFn guarantees atomics live only in the
    // entry body, so the backing buffer is threaded solely through the entry signature
    // (the same single-function discipline as the compute path).
    if (atomic_images.count() > 0) {
        if (options.argument_buffers or (module.execution_model != .GLCompute and module.execution_model != .Fragment)) return error.UnsupportedOp;
        if (imageAtomicInNonEntryFn(&module, entry_id)) return error.UnsupportedOp;
        var ai = atomic_images.keyIterator();
        while (ai.next()) |vid| {
            if (mslAtomicImageScalar(&module, vid.*) == null) return error.UnsupportedOp;
        }
        try w.writeAll(spv_image2d_atomic_template);
    }

    const need_unsafe_array = moduleNeedsUnsafeArray(&module);
    if (need_unsafe_array) try w.writeAll(spv_unsafe_array_template);

    // Metal has no matrix inverse() builtin — emit the closed-form helper(s) once for
    // each dimension actually used (gated by a module scan), then call them at use sites.
    const inv_dims = moduleInverseDims(&module);
    if (inv_dims.n2) try w.writeAll(spv_inverse2_template);
    if (inv_dims.n3) try w.writeAll(spv_inverse3_template);
    if (inv_dims.n4) try w.writeAll(spv_inverse4_template);

    // Emit struct forward declarations for types used in uniform/storage blocks
    // These must come before the block declarations
    var emitted_structs = std.AutoHashMap(u32, void).init(aa);
    defer emitted_structs.deinit();
    var emitted_names_msl = std.StringHashMap(void).init(aa);
    defer emitted_names_msl.deinit();
    for (cbuffers.items) |cb| {
        // The synthesized _Globals block (type_id 0) has no backing SPIR-V struct
        // to forward-declare its members from; skip it here (#417).
        if (cb.type_id == 0) continue;
        // Propagate errors (not `catch {}`): these forward decls now emit full
        // std140/std430 member layouts via emitStructMembers, which can honest-
        // error on an unsupported member. Swallowing it would write a truncated
        // `struct Foo {` with no closing `}` — fail loud instead, matching the
        // top-level block emission below (which uses `try`).
        try mslEmitStructForwardDecls(&module, &names, cb.type_id, w, aa, &emitted_structs, &emitted_names_msl, &member_offsets, &decs);
    }
    if (emitted_structs.count() > 0) try w.writeAll("\n");

    // Emit uniform blocks as structs
    for (cbuffers.items) |cb| {
        try w.print("struct {s}\n{{\n", .{cb.name});
        if (cb.type_id == 0) {
            // Synthesized _Globals block: members come from the gathered loose
            // uniforms, not a SPIR-V struct type (#417).
            for (loose_uniforms.items) |lu| {
                const mt = try mslType(&module, lu.type_id, &names, aa);
                try w.print("    {s} {s};\n", .{ mt, lu.name });
            }
        } else {
            try emitStructMembers(&module, &names, cb.type_id, cb.name, w, aa, &member_offsets, &decs);
        }
        try w.writeAll("};\n\n");
    }

    // Collect SSBO-style storage buffers (StorageBuffer storage class or Uniform + BufferBlock decoration)
    var storage_buffers = std.ArrayList(CbufferDecl).initCapacity(aa, 8) catch return error.OutOfMemory;
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            const rid = inst.words[2];
            // SSBOs use StorageBuffer storage class (SPIR-V 1.3+) or Uniform + BufferBlock
            // decoration. BufferBlock decorates the struct TYPE (SPIR-V spec), not the
            // variable, so resolve the pointee and check it there -- checking the
            // variable id always missed old-style Uniform+BufferBlock SSBOs.
            const pointee_type = resolvePointee(&module, rid);
            const is_ssbo = sc == .StorageBuffer or
                (sc == .Uniform and pointee_type != null and hasDec(&decs, pointee_type.?, .buffer_block));
            if (!is_ssbo) continue;
            const binding = getDecVal(&decs, rid, .binding) orelse continue;
            const set = getDecVal(&decs, rid, .descriptor_set) orelse 0;
            const name = names.get(rid) orelse continue;
            const ptr_inst = getDef(&module, inst.words[1]) orelse continue;
            if (ptr_inst.op == .TypePointer and ptr_inst.words.len >= 4) {
                const ptid = ptr_inst.words[3];
                storage_buffers.append(aa, .{ .name = name, .type_id = ptid, .binding = binding, .descriptor_set = set }) catch {};
            }
        }
    }

    // Honest-error: descriptor-array storage buffers ('buffer B { ... } name[N]')
    // have a TypeArray pointee. Metal can't express descriptor arrays without
    // argument buffers or the spirv-cross unrolled-parameter approach (which
    // requires pointer `->` access the emitter doesn't support). Refuse.
    for (storage_buffers.items) |sb| {
        const sb_type = getDef(&module, sb.type_id);
        if (sb_type != null and sb_type.?.op == .TypeArray) {
            return error.UnsupportedDescriptorArray;
        }
    }

    // Emit storage buffer structs for compute
    if (storage_buffers.items.len > 0) {
        for (storage_buffers.items) |sb| {
            try mslEmitStructForwardDecls(&module, &names, sb.type_id, w, aa, &emitted_structs, &emitted_names_msl, &member_offsets, &decs);
        }
        for (storage_buffers.items) |sb| {
            try w.print("struct {s}\n{{\n", .{sb.name});
            try emitStructMembers(&module, &names, sb.type_id, sb.name, w, aa, &member_offsets, &decs);
            try w.writeAll("};\n\n");
        }
    }

    // M6 v2: argument-buffer descriptor-set struct emission.
    //
    // When options.argument_buffers is true, emit one
    // `spvDescriptorSetBufferN` struct per descriptor set actually used by
    // the entry point. Each struct contains only its own set's resources
    // with `[[id(K)]]` slots restarting at 0 inside each set (this matches
    // SPIRV-Cross). `binding_shift` is applied to the outer `[[buffer(N)]]`
    // of the set parameter itself (see entry-point emission below), NOT to
    // the inner `[[id(K)]]` slots.
    //
    // v2.b: storage buffers participate in the set struct as
    // `device Buf* sb [[id(K)]]`. When `argument_buffers` is false, SSBOs
    // continue to bind via the legacy per-resource path.
    if (options.argument_buffers and (cbuffers.items.len > 0 or textures.items.len > 0 or storage_buffers.items.len > 0)) {
        // Gather the unique set indices used across all resource kinds, in
        // ascending order. Skip empty sets (don't emit unused structs).
        var set_indices = std.ArrayList(u32).initCapacity(aa, 4) catch return error.OutOfMemory;
        for (cbuffers.items) |cb| try addUniqueSet(&set_indices, cb.descriptor_set, aa);
        for (textures.items) |t| try addUniqueSet(&set_indices, t.descriptor_set, aa);
        for (storage_buffers.items) |sb| try addUniqueSet(&set_indices, sb.descriptor_set, aa);
        std.mem.sort(u32, set_indices.items, {}, std.sort.asc(u32));

        for (set_indices.items) |set_idx| {
            try w.print("struct spvDescriptorSetBuffer{d}\n{{\n", .{set_idx});
            var id_slot: u32 = 0;
            for (cbuffers.items) |cb| {
                if (cb.descriptor_set != set_idx) continue;
                try w.print("    constant {s}& {s} [[id({d})]];\n", .{ cb.name, cb.name, id_slot });
                id_slot += 1;
            }
            for (textures.items) |tex| {
                if (tex.descriptor_set != set_idx) continue;
                try w.print("    {s} {s} [[id({d})]];\n", .{ tex.msl_type, tex.name, id_slot });
                id_slot += 1;
                // Storage images (#284 follow-up) take no sampler — consuming a
                // single [[id]] slot, matching spirv-cross. Sampled images take a
                // second slot for their `sampler`.
                if (!tex.is_storage) {
                    try w.print("    sampler {s}Smplr [[id({d})]];\n", .{ tex.name, id_slot });
                    id_slot += 1;
                }
            }
            for (storage_buffers.items) |sb| {
                if (sb.descriptor_set != set_idx) continue;
                try w.print("    device {s}* {s} [[id({d})]];\n", .{ sb.name, sb.name, id_slot });
                id_slot += 1;
            }
            try w.writeAll("};\n\n");
        }
    }

    // #472: a FRAGMENT Output that is GENUINELY Metal-unrepresentable (a struct output,
    // or an output builtin other than FragDepth/SampleMask/FragStencilRefEXT) cannot
    // become a valid main0_out field — honest-error it. The representable multi-output
    // kinds (MRT/dual-source/FragDepth/SampleMask/stencil) now have a real main0_out path.
    if (is_frag and hasUnsupportedFragOutput(&module, &names, &decs)) {
        return error.UnsupportedFragmentOutput;
    }
    // A multisampled storage image that is both read and written: Metal texture2d_ms
    // rejects access::read_write, so it cannot be one Metal texture. Honest-error
    // (genuinely Metal-limited) -- was silent-wrong (image-ms).
    if (mslHasReadWriteMSStorageImage(&module, &img_access)) {
        return error.UnsupportedMultiSampleStorageImage;
    }
    // Output struct for fragment. The SINGLE-color common case (one Location-0 color,
    // no builtin) takes the legacy hardcoded path UNCHANGED (byte-identical for 1416+
    // shaders). The multi-output case (MRT/FragDepth/SampleMask/stencil/dual-source)
    // emits one main0_out field per output, mirroring spirv-cross --msl.
    if (is_frag) {
        if (frag_multi) {
            try w.writeAll("struct main0_out\n{\n");
            for (frag_outputs.items) |fo| {
                const tn = fragOutputMslType(&module, fo, &names, aa);
                switch (fo.kind) {
                    .color => {
                        if (fo.index) |idx| {
                            try w.print("    {s} {s} [[color({d}), index({d})]];\n", .{ tn, fo.name, fo.location, idx });
                        } else {
                            try w.print("    {s} {s} [[color({d})]];\n", .{ tn, fo.name, fo.location });
                        }
                    },
                    .frag_depth => try w.print("    {s} {s} [[{s}]];\n", .{ tn, fo.name, fragmentDepthAttribute(&module, entry_id) }),
                    .sample_mask => try w.print("    {s} {s} [[sample_mask]];\n", .{ tn, fo.name }),
                    .stencil_ref => try w.print("    {s} {s} [[stencil]];\n", .{ tn, fo.name }),
                }
            }
            try w.writeAll("};\n\n");
        } else {
            // A fragment with NO Output variables at all is a VOID fragment: emit no
            // main0_out (the entry is `fragment void main0(...)`). The legacy fallback
            // synthesized `float _fragColor [[color(0)]]`, writing zeros to the color
            // attachment where SPIR-V semantics (and spirv-cross --msl) write nothing -
            // the same miscompile class the WARP gate found in the HLSL backend (a
            // full-image alpha flip vs the untouched clear, maxdiff 255 on 65536 px).
            // An empty main0_out struct was tried before and regressed Metal validity;
            // void is the correct shape (Metal allows void fragment functions).
            var frag_has_any_output = false;
            for (module.instructions) |inst| {
                if (inst.op != .Variable or inst.words.len < 4) continue;
                if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) == .Output) {
                    frag_has_any_output = true;
                    break;
                }
            }
            if (frag_has_any_output) {
                const oty = fragmentOutputMslType(&module, &names, &decs, aa);
                try w.print("struct main0_out\n{{\n    {s} _fragColor [[color(0)]];\n}};\n\n", .{oty});
            }
        }
    }

    // Output struct for vertex (mirrors spirv-cross --msl): user varyings
    // `T name [[user(locnN)]]` in ascending Location order, then `gl_Position
    // [[position]]` LAST. collectStageOutputs already orders the list this way
    // (varyings sorted by location, gl_Position appended last).
    if (is_vertex and stage_outputs.items.len > 0) {
        try w.writeAll("struct main0_out\n{\n");
        var has_position = false;
        // Metal requires unique field names in a struct. A shader with both a
        // block output AND a standalone output sharing member names (e.g.
        // out-block-qualifiers.vert: 'out VertexData { float f; } vout;' +
        // 'out flat float f;') would produce duplicate main0_out fields.
        // The correct Metal translation requires local-struct reconstruction
        // (spirv-cross's approach); honest-error until that lands.
        var seen_field_names = std.StringHashMap(void).init(aa);
        defer seen_field_names.deinit();
        for (stage_outputs.items) |so| {
            if (so.is_position) {
                has_position = true;
                try w.print("    {s} {s} [[position]];\n", .{ try mslType(&module, so.type_id, &names, aa), so.name });
            } else if (so.is_point_size) {
                try w.print("    {s} {s} [[point_size]];\n", .{ try mslType(&module, so.type_id, &names, aa), so.name });
            } else {
                // Matrix-typed vertex output: Metal rejects matrix main0_out
                // fields ('field of illegal type vec<T,R>[C]'); flatten to per-column
                // vectors (spirv-cross idiom: m22_0, m22_1, ...). The store is
                // scattered to columns in the Store handler.
                const mty = getDef(&module, so.type_id);
                if (mty != null and mty.?.op == .TypeMatrix and mty.?.words.len >= 4) {
                    const cols = mty.?.words[3];
                    const vt = try mslType(&module, mty.?.words[2], &names, aa);
                    var ci: u32 = 0;
                    while (ci < cols) : (ci += 1) {
                        try w.print("    {s} {s}_{d} [[user(locn{d})]];\n", .{ vt, so.name, ci, so.location + ci });
                    }
                } else {
                    // Check for duplicate field name (block + standalone collision).
                    if (seen_field_names.contains(so.name)) return error.DuplicateOutputFieldName;
                    seen_field_names.put(so.name, {}) catch {};
                    try w.print("    {s} {s} [[user(locn{d})]];\n", .{ try mslType(&module, so.type_id, &names, aa), so.name, so.location });
                }
            }
        }
        // Metal requires every vertex function's return struct to carry a
        // [[position]] output. A vertex shader that writes no gl_Position (e.g. a
        // fragment-class shader cross-compiled under the vertex stage) would
        // otherwise be rejected; add a default position member, matching spirv-cross.
        if (!has_position) {
            try w.writeAll("    float4 gl_Position [[position]];\n");
        }
        try w.writeAll("};\n\n");
    }

    // #500: Metal's [[stage_in]] accepts only scalar/vector/matrix fields, NOT
    // struct-typed ones. collectStageInputs flattens interface blocks ONE level,
    // so a block member (or a direct `in` variable) that is itself a struct --
    // e.g. `in VertexIn { Foo a; Bar b; }` or `in Baz baz` where Foo/Bar/Baz are
    // structs -- still yields a struct-typed main0_in field (`Foo VertexIn_a
    // [[user(locn0)]]`), which Metal rejects ("invalid type 'main0_in' ...
    // stage_in"). spirv-cross handles this by RECURSIVELY flattening to
    // scalar/vector leaves and reconstructing the struct at use sites.
    //
    // Honest-error until the recursive flatten lands. That is a 3-site change on
    // hot paths shared by every valid shader: (1) collectStageInputs recursive
    // leaf walk, (2) access-chain rewrite consuming a run of constant struct-
    // member indices to the leaf (today it eats one), (3) whole-struct-load
    // reconstruction emitting nested brace literals (today one-level), plus a
    // richer block_flat key for nested access (baz.foo.b). layout-component
    // additionally needs component-packing and is tracked with this same follow-up.
    //
    // Follow-up ENTRY CRITERIA (do not let this rot -- struct-typed stage inputs
    // are rare in THIS corpus (2/1453) but common in production GLSL, so this is
    // a correctness floor, not an achievement): land the flatten as one cohesive
    // subsystem covering struct-flatten AND component-packing, gated on a full-
    // corpus Metal regression sweep (tools/msl_validity_sweep.sh must stay green
    // or improve) so the flatten cannot silently regress the valid shaders.
    // (#500 struct-typed stage inputs are now RECURSIVELY FLATTENED to scalar/
    // vector leaves in collectStageInputs, so no struct-typed main0_in fields
    // remain to reject here. The UnsupportedStructStageInput honest-error is
    // retired; the recursive flatten + nested-brace load reconstruction handle
    // them. Component packing below is a SEPARATE, still-unsupported feature.)
    // Component packing: GLSL/Vulkan lets two stage inputs share one Location,
    // distinguished by `component` (e.g. `layout(location=0, component=0) in
    // vec2 v0; layout(location=0, component=2) in float v1;`). Metal's
    // [[user(locnN)]] has no component offset; spirv-cross widens to a vec4 and
    // swizzles, which zioshade doesn't do. Worse, the frontend currently DROPS
    // Component decorations, so same-Location inputs collide on the same
    // [[user(locnN)]] and Metal rejects main0_in. Two inputs at the same Location
    // is the exact signal that component packing is in play (it's the only valid
    // Vulkan way to share a Location) -- detect it and honest-error.
    // (layout-component.desktop.frag.) Same follow-up / entry criteria as #500.
    // collectStageInputs sorts stage_inputs ascending by Location, so equal
    // Locations are adjacent.
    if (stage_inputs.items.len > 1) {
        // Same Location is valid ONLY with distinct Components (component
        // packing). A genuine collision = same Location AND same Component
        // (incl. both unset). O(n^2) is fine (stage_inputs is small); an
        // adjacent scan would miss same-comp pairs split by a different-comp
        // input at the same Location.
        var i: usize = 0;
        while (i < stage_inputs.items.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < stage_inputs.items.len) : (j += 1) {
                const a = stage_inputs.items[i];
                const b = stage_inputs.items[j];
                if (a.location == b.location and (a.component orelse 0) == (b.component orelse 0))
                    return error.UnsupportedComponentPacking;
            }
        }
    }
    // Stage-in struct for location inputs (mirrors spirv-cross --msl
    // `struct main0_in { T name [[attr]]; }`). Emitted only when there is at
    // least one location input. Built-ins (gl_FragCoord etc.) are excluded by
    // collectStageInputs and stay on their builtin path. The attribute spelling
    // is stage-gated: fragment → `[[user(locnN)]]`, vertex → `[[attribute(N)]]`.
    if ((is_frag or is_vertex) and stage_inputs.items.len > 0) {
        // A stage-in field can be struct-typed (a nested interface-block member, e.g.
        // Foo). main0_in is emitted BEFORE the full struct decls, so emit those struct
        // types fully here (recursively, deduped via emitted_names_msl so the later
        // local-struct pass skips them) to avoid "unknown type name".
        for (stage_inputs.items) |si| {
            if (getDef(&module, si.type_id)) |t| {
                if (t.op == .TypeStruct) {
                    mslEmitOneStructForwardDecl(&module, &names, si.type_id, w, aa, &emitted_structs, &emitted_names_msl) catch {};
                }
            }
        }
        try w.writeAll("struct main0_in\n{\n");
        for (stage_inputs.items) |si| {
            const tn = try mslType(&module, si.type_id, &names, aa);
            if (is_vertex) {
                try w.print("    {s} {s} [[attribute({d})]];\n", .{ tn, si.name, si.location });
            } else if (pull_model.contains(si.var_id)) {
                // Pull-model interpolated input: declare as interpolant<T, P> so the
                // body can call .interpolate_at_centroid()/_sample()/_offset()/_center().
                // spirv-cross uses interpolation::perspective for these (even for flat).
                try w.print("    interpolant<{s}, interpolation::perspective> {s} [[user(locn{d})]];\n", .{ tn, si.name, si.location });
            } else {
                // Component packing: Metal natively supports a component-
                // qualified location attribute [[user(locnN_M)]] (spirv-cross
                // uses this for `layout(location=N, component=M)`).
                if (si.component) |comp| {
                    try w.print("    {s} {s} [[user(locn{d}_{d}){s}]];\n", .{ tn, si.name, si.location, comp, si.interp });
                } else {
                    try w.print("    {s} {s} [[user(locn{d}){s}]];\n", .{ tn, si.name, si.location, si.interp });
                }
            }
        }
        try w.writeAll("};\n\n");
    }

    var func_ids = std.ArrayList(u32).initCapacity(aa, 8) catch return error.OutOfMemory;
    defer func_ids.deinit(aa);
    for (module.instructions) |inst| {
        if (inst.op == .Function and inst.words.len > 2) try func_ids.append(aa, inst.words[2]);
    }

    var out_param_info = std.AutoHashMap(u32, std.ArrayList(usize)).init(aa);
    defer {
        var it = out_param_info.iterator();
        while (it.next()) |e| e.value_ptr.deinit(aa);
        out_param_info.deinit();
    }
    common.detectOutParams(module.instructions, module.id_defs, entry_id, &out_param_info, aa);

    // Emit specialization constants as MSL constant declarations
    for (module.instructions) |inst| {
        const is_scalar_sc = inst.op == .SpecConstant and inst.words.len > 3;
        const is_bool_sc = (inst.op == .SpecConstantTrue or inst.op == .SpecConstantFalse) and inst.words.len > 2;
        if (!is_scalar_sc and !is_bool_sc) continue;
        const result_id = inst.words[2];
        const name = names.get(result_id) orelse continue;
        const type_id = inst.words[1];
        const type_str = try mslType(&module, type_id, &names, aa);
        const spec_id: ?u32 = blk: {
            const dec_list = decs.get(result_id) orelse break :blk null;
            for (dec_list.items) |d| {
                if (d.decoration == .spec_id and d.extra.len > 0) break :blk d.extra[0];
            }
            break :blk null;
        };
        const sid = spec_id orelse continue;
        // MSL forbids an initializer on a `[[function_constant(N)]]` variable
        // ("variable with 'function_constant' attribute cannot have an initializer"),
        // so mirror spirv-cross: a `<name>_tmp` holds the function constant (no
        // init), and `<name>` selects it via is_function_constant_defined, falling
        // back to the SPIR-V default. The body references `<name>` (unchanged).
        if (is_bool_sc) {
            const bool_val: []const u8 = if (inst.op == .SpecConstantTrue) "true" else "false";
            try w.print("constant bool {s}_tmp [[function_constant({d})]];\n", .{ name, sid });
            try w.print("constant bool {s} = is_function_constant_defined({s}_tmp) ? {s}_tmp : {s};\n", .{ name, name, name, bool_val });
        } else {
            const default_val = inst.words[3];
            try w.print("constant {s} {s}_tmp [[function_constant({d})]];\n", .{ type_str, name, sid });
            if (std.mem.eql(u8, type_str, "float")) {
                const fv: f32 = @bitCast(default_val);
                try w.print("constant {s} {s} = is_function_constant_defined({s}_tmp) ? {s}_tmp : {d};\n", .{ type_str, name, name, name, fv });
            } else if (std.mem.eql(u8, type_str, "int")) {
                // #475: a signed-int default's high bit set (e.g. -1) must print as the
                // NEGATIVE value, not the raw u32 (4294967295) — out-of-range int literal.
                const iv: i32 = @bitCast(default_val);
                try w.print("constant {s} {s} = is_function_constant_defined({s}_tmp) ? {s}_tmp : {d};\n", .{ type_str, name, name, name, iv });
            } else {
                try w.print("constant {s} {s} = is_function_constant_defined({s}_tmp) ? {s}_tmp : {d};\n", .{ type_str, name, name, name, default_val });
            }
        }
    }
    // OpSpecConstantComposite: assemble the vec/mat from the per-scalar function
    // constants. MSL doesn't support `[[function_constant(N)]]` on composite
    // types directly, so we declare a plain `constant` that materialises from
    // the (possibly overridden) per-scalar function constants.
    for (module.instructions) |inst| {
        if (inst.op != .SpecConstantComposite or inst.words.len <= 3) continue;
        const result_id = inst.words[2];
        const name = names.get(result_id) orelse continue;
        const type_id = inst.words[1];
        const type_str = try mslType(&module, type_id, &names, aa);
        const constituents = inst.words[3..];
        try w.print("constant {s} {s} = {s}(", .{ type_str, name, type_str });
        for (constituents, 0..) |c_id, i| {
            if (i > 0) try w.writeAll(", ");
            const c_name = names.get(c_id) orelse "0";
            try w.writeAll(c_name);
        }
        try w.writeAll(");\n");
    }
    // M3.5: emit OpSpecConstantOp as derived const expressions. MSL's
    // SPIRV-Cross compatible idiom is `constant T X = a OP b;` -- the
    // value is computed at function-constant binding time when MSL
    // materialises function_constants.
    for (module.instructions) |inst| {
        if (inst.op != .SpecConstantOp or inst.words.len < 5) continue;
        const type_id = inst.words[1];
        const result_id = inst.words[2];
        const opcode_lit = inst.words[3];
        const name = names.get(result_id) orelse continue;
        const type_str = try mslType(&module, type_id, &names, aa);
        if (inst.words.len == 5) {
            const op0 = names.get(inst.words[4]) orelse continue;
            const uop: ?[]const u8 = switch (opcode_lit) {
                126, 127 => "-",
                200 => "~",
                else => null,
            };
            if (uop) |u| try w.print("constant {s} {s} = {s}({s});\n", .{ type_str, name, u, op0 });
            continue;
        }
        // OpSelect (ternary): constant T name = cond ? tv : fv;
        // words = [hdr, type, result, 169, cond, true, false].
        if (opcode_lit == 169 and inst.words.len == 7) {
            const cond = names.get(inst.words[4]) orelse continue;
            const tv = names.get(inst.words[5]) orelse continue;
            const fv = names.get(inst.words[6]) orelse continue;
            try w.print("constant {s} {s} = ({s}) ? ({s}) : ({s});\n", .{ type_str, name, cond, tv, fv });
            continue;
        }
        const op_str: ?[]const u8 = switch (opcode_lit) {
            128, 129 => "+",
            130, 131 => "-",
            132, 133 => "*",
            134, 135, 136 => "/",
            137, 138, 139, 140, 141 => "%",
            194, 195 => ">>",
            196 => "<<",
            197 => "|",
            198 => "^",
            199 => "&",
            // Integer/float comparisons (result type is bool). Ord and Unord
            // float variants map to the same C operator; spec-constant bool
            // results are uncommon, but glslang emits these for ternaries
            // over spec constants (e.g. `s > 10u ? a : b`).
            170, 180, 181 => "==",
            171, 182, 183 => "!=",
            172, 173, 186, 187 => ">",
            174, 175, 190, 191 => ">=",
            176, 177, 184, 185 => "<",
            178, 179, 188, 189 => "<=",
            else => null,
        };
        const op = op_str orelse continue;
        if (inst.words.len != 6) continue;
        const op0 = names.get(inst.words[4]) orelse continue;
        const op1 = names.get(inst.words[5]) orelse continue;
        try w.print("constant {s} {s} = {s} {s} {s};\n", .{ type_str, name, op0, op, op1 });
    }
    try w.writeAll("\n");

    // Emit struct declarations for types used as local variables. C7: this MUST
    // precede the module-scope array-constant block below, because a value-copied
    // struct-element const array is materialized as `constant spvUnsafeArray<S,N>`
    // — referencing `struct S`, which would otherwise be used before its
    // declaration (uncompilable Metal). spirv-cross likewise declares the struct
    // first.
    var local_structs_msl = std.AutoHashMap(u32, void).init(aa);
    defer local_structs_msl.deinit();
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            // Private as well as Function: a Private global of user-struct type is
            // promoted to an entry-impl local and threaded into helpers, so its TYPE
            // needs declaring at module scope exactly like a Function local's does.
            // Scanning only Function storage left `QuicksortObject obj;` referring to
            // a type that was never declared.
            if (sc == .Function or sc == .Private) {
                const ptr_type = inst.words[1];
                const ptr_inst = getDef(&module, ptr_type) orelse continue;
                if (ptr_inst.op == .TypePointer and ptr_inst.words.len >= 4) {
                    var pointee_id = ptr_inst.words[3];
                    var pt_inst = getDef(&module, pointee_id) orelse continue;
                    // Unwrap array types to find underlying struct
                    while (pt_inst.op == .TypeArray and pt_inst.words.len > 2) {
                        pointee_id = pt_inst.words[2];
                        pt_inst = getDef(&module, pointee_id) orelse break;
                    }
                    if (pt_inst.op == .TypeStruct) {
                        mslEmitOneStructForwardDecl(&module, &names, pointee_id, w, aa, &local_structs_msl, &emitted_names_msl) catch {};
                    }
                }
            }
        }
    }
    // Structs that appear only as SSA VALUES (an inlined function's struct locals
    // become OpCompositeConstruct/OpFunctionCall results, not OpVariables) are
    // missed by the OpVariable scan above; declare them too.
    for (module.instructions) |inst| {
        if (common.structValueTypeId(&module, inst)) |sid| {
            mslEmitOneStructForwardDecl(&module, &names, sid, w, aa, &local_structs_msl, &emitted_names_msl) catch {};
        }
    }
    if (local_structs_msl.count() > 0) try w.writeAll("\n");

    // Module-scope array constants. Each array `OpConstantComposite` referenced
    // by name — i.e. the initializer of a promoted read-only function-local
    // const array OR of a const-initialized Private global — is emitted as a
    // Metal `constant T name[dims] = {…};`. Metal requires the `constant`
    // address space for a program-scope array referenced from a function.
    // Nested array/struct constituents are inlined into the brace initializer.
    // Composites consumed only as a mutated local's in-place initializer are NOT
    // named here (they are brace-initialized at the declaration instead).
    {
        var named_consts = std.AutoHashMap(u32, void).init(aa);
        defer named_consts.deinit();
        // Consts that are whole-array value-copied somewhere (the source of a
        // `float local[N] = LUT;`): these must be spelled `spvUnsafeArray<…>`
        // (template assignment), not the plain `constant T[N]` C-array, so the
        // copy is legal Metal. A const that is ONLY indexed stays a plain
        // `constant T[N]` (simpler, valid; intentional spirv-cross divergence).
        var value_copied_consts = std.AutoHashMap(u32, void).init(aa);
        defer value_copied_consts.deinit();
        for (module.instructions) |inst| {
            if (inst.op != .Variable) continue;
            if (analyzeLocalConstArray(&module, inst)) |info| {
                if (!info.mutated) {
                    named_consts.put(info.init_id, {}) catch {};
                    if (arrayLoadedAsValue(&module, inst.words[2])) value_copied_consts.put(info.init_id, {}) catch {};
                }
            }
            if (common.constInitializedPrivateVar(&module, inst)) |init_id| {
                named_consts.put(init_id, {}) catch {};
                if (arrayLoadedAsValue(&module, inst.words[2])) value_copied_consts.put(init_id, {}) catch {};
            }
        }
        // An OpConstantComposite array referenced BY NAME in a function body
        // (Load/AccessChain/CompositeExtract/… operand) but not caught by the
        // local/Private analysis above (e.g. a const array indexed directly without
        // a promoting local) still needs a module-scope declaration, or the body
        // reference is an undeclared identifier. GLSL emits these unconditionally;
        // surface them here. Default to the spvUnsafeArray spelling, which supports
        // both [] indexing and whole-array copy, so it is valid however it is used.
        for (module.instructions) |inst| {
            switch (inst.op) {
                .Load, .AccessChain, .CompositeExtract, .CompositeInsert, .VectorShuffle, .CompositeConstruct, .Select, .CopyObject => {
                    for (inst.words[3..]) |op| {
                        if (named_consts.contains(op)) continue;
                        const cdef = getDef(&module, op) orelse continue;
                        if (cdef.op != .ConstantComposite or cdef.words.len <= 3) continue;
                        const tdef = getDef(&module, cdef.words[1]) orelse continue;
                        if (tdef.op != .TypeArray) continue;
                        named_consts.put(op, {}) catch {};
                        value_copied_consts.put(op, {}) catch {};
                    }
                },
                else => {},
            }
        }
        var emitted_const_array = false;
        for (module.instructions) |inst| {
            if (inst.op != .ConstantComposite or inst.words.len <= 3) continue;
            const rid = inst.words[2];
            if (!named_consts.contains(rid)) continue;
            const type_inst = getDef(&module, inst.words[1]) orelse continue;
            if (type_inst.op != .TypeArray) continue;
            const name = names.get(rid) orelse continue;
            // Value-copied → emit as `constant spvUnsafeArray<…> name =
            // spvUnsafeArray<…>({…});` (matches spirv-cross; legal copy source).
            if (value_copied_consts.contains(rid)) {
                const vt = mslValueType(&module, inst.words[1], &names, aa) catch continue;
                try w.print("constant {s} {s} = {s}(", .{ vt, name, vt });
                try writeMslConstInit(&module, &names, w, rid, aa);
                try w.writeAll(");\n");
                emitted_const_array = true;
                continue;
            }
            // Walk nested TypeArray dimensions, collecting the base element type.
            var dims = std.ArrayList(u32).initCapacity(aa, 2) catch continue;
            defer dims.deinit(aa);
            const outer_len = getDef(&module, type_inst.words[3]);
            dims.append(aa, if (outer_len) |ld| ld.words[3] else 1) catch {};
            var elem_id = type_inst.words[2];
            var inner = getDef(&module, elem_id);
            while (inner) |inn| {
                if (inn.op == .TypeArray and inn.words.len > 3) {
                    const ild = getDef(&module, inn.words[3]);
                    dims.append(aa, if (ild) |l| l.words[3] else 1) catch {};
                    elem_id = inn.words[2];
                    inner = getDef(&module, elem_id);
                } else break;
            }
            const base_type = try mslType(&module, elem_id, &names, aa);
            try w.print("constant {s} {s}", .{ base_type, name });
            for (dims.items) |d| try w.print("[{d}]", .{d});
            try w.writeAll(" = ");
            try writeMslConstInit(&module, &names, w, rid, aa);
            try w.writeAll(";\n");
            emitted_const_array = true;
        }
        if (emitted_const_array) try w.writeAll("\n");
    }

    // Faithful runtime SSBO `.length()` (#296): assign each storage buffer that is the
    // structure operand of an OpArrayLength a slot in the host-provided
    // `spvBufferSizeConstants` array (spirv-cross's scheme). Only wired for the COMPUTE,
    // non-argbuf path with NO co-occurring image-atomic backing buffer (which competes for
    // the same trailing [[buffer]] slots). When the map stays empty, the `.ArrayLength`
    // arm honest-errors — keeping the param emission and the body emission coupled.
    var arraylen_buf_index = std.AutoHashMap(u32, u32).init(aa);
    if (is_compute and !options.argument_buffers and atomic_images.count() == 0) {
        var next_size_idx: u32 = 0;
        for (module.instructions) |inst| {
            if (inst.op == .ArrayLength and inst.words.len >= 4) {
                const sp = inst.words[3];
                if (!arraylen_buf_index.contains(sp)) {
                    arraylen_buf_index.put(sp, next_size_idx) catch {};
                    next_size_idx += 1;
                }
            }
        }
    }
    // `spvBufferSizeConstants` is injected ONLY into the entry kernel signature, so the
    // faithful `.length()` lowering must fire only in the entry function body. Non-entry
    // (helper) functions get an EMPTY map → their `.ArrayLength` arm honest-errors instead
    // of referencing an undeclared `spvBufferSizeConstants` (the same non-entry honest-error
    // discipline as the #267 image-atomic backing buffer). A helper `arr.length()` thus
    // fails loud rather than emitting silent-wrong MSL.
    var arraylen_empty = std.AutoHashMap(u32, u32).init(aa);

    // #476: thread location stage inputs into non-entry functions. A varying used
    // inside a helper function (e.g. gl_HelperInvocation's foo(), or a Vulkan
    // combined-sampler's texcoord) would otherwise reference a bare `vTex` that is
    // only in scope in the entry, where inputs are aliased to `in.<name>`. Rename
    // the inputs to `in.<name>` BEFORE emitting non-entry functions (they are
    // emitted before the entry, which does its own rename), give every non-entry
    // function a `main0_in in` parameter, and pass `in` at each call site. Gated on
    // is_frag + non-empty stage inputs, so wintty (no varyings) is byte-identical.
    // The stage-in struct was already emitted above from the captured decl names,
    // so this body-only rename does not affect field spellings.
    g_has_stage_in = stage_inputs.items.len > 0;
    defer g_has_stage_in = false;
    // #489: thread the fragment output into helpers (set type+name; read at the helper
    // signature + OpFunctionCall). Null when there is no Location-0 color output. The
    // multi-output path (#472) threads ALL outputs via g_frag_outputs instead, so this
    // single-output threading is skipped there to avoid a duplicate param.
    g_frag_out_type = null;
    g_frag_out_name = null;
    defer {
        g_frag_out_type = null;
        g_frag_out_name = null;
    }
    if (is_frag and !frag_multi) {
        for (module.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Output) continue;
            const rid = inst.words[2];
            const loc = getDecVal(&decs, rid, .location) orelse continue;
            if (loc != 0) continue;
            g_frag_out_type = fragmentOutputMslType(&module, &names, &decs, aa);
            g_frag_out_name = names.get(rid) orelse "_fragColor";
            break;
        }
    }
    // #489 (builtin threading): rename gl_FragCoord -> _fragCoord BEFORE helpers are
    // emitted (the entry path does it too late), so a helper reading it resolves to the
    // threaded _fragCoord param. Compute fc_ty here too (idempotent with the entry path).
    g_frag_coord_ty = null;
    defer g_frag_coord_ty = null;
    if (is_frag) {
        for (module.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Input) continue;
            const vid = inst.words[2];
            const dlist = decs.get(vid) orelse continue;
            var is_fc = false;
            for (dlist.items) |de| {
                if (de.decoration == .built_in and de.extra.len > 0 and de.extra[0] == @intFromEnum(spirv.BuiltIn.frag_coord)) {
                    is_fc = true;
                    break;
                }
            }
            if (!is_fc) continue;
            const pa = aa.dupe(u8, "_fragCoord") catch break;
            _ = names.put(vid, pa) catch {};
            g_frag_coord_ty = if (fragCoordNeedsFullVec(&module, vid)) "float4" else "float2";
            break;
        }
    }
    // Same timing rationale as g_frag_coord_ty above: helpers are emitted BEFORE the
    // entry, so the threaded-parameter set has to exist now. Fragment only, because
    // this list must match the set the fragment entry path declares as locals.
    g_priv_globals = null;
    defer g_priv_globals = null;
    var priv_globals = std.ArrayList(PrivGlobal).initCapacity(aa, 0) catch return error.OutOfMemory;
    if (is_frag) {
        collectThreadedPrivGlobals(&module, &names, &priv_globals, aa);
        if (priv_globals.items.len > 0) g_priv_globals = priv_globals.items;
    }
    if (g_has_stage_in) {
        // This is now the SOLE stage-input rename (the entry function's own copy is
        // removed): doing it here, before non-entry functions are emitted, lets a
        // varying used inside a helper resolve to `in.<name>` too. Arena-allocated
        // (all names come from collectNames on the arena); the prior arena name is
        // reclaimed at arena.deinit, so it is overwritten without an explicit free.
        for (stage_inputs.items) |si| {
            const aliased = if (pull_model.contains(si.var_id))
                std.fmt.allocPrint(aa, "in.{s}{s}", .{ si.name, pull_model_center_suffix }) catch continue
            else
                std.fmt.allocPrint(aa, "in.{s}", .{si.name}) catch continue;
            _ = names.fetchPut(si.var_id, aliased) catch {};
        }
    }

    // #480: when a non-entry function forward-calls a callee defined later
    // (mutual recursion), emit C prototypes for all non-entry functions first,
    // reusing the exact signature emitter so definitions match. Gated on an actual
    // forward call, so shaders with none (e.g. wintty's single mainImage) stay
    // byte-identical.
    if (needsForwardDecls(&module, func_ids.items, entry_id)) {
        g_proto_only = true;
        for (func_ids.items) |fid| {
            if (fid == entry_id) continue;
            try emitFunction(&module, &names, &decs, fid, w, aa, false, &out_param_info, &cbuffers, &textures, &storage_buffers, &stage_inputs, &stage_outputs, is_compute_like, options.binding_shift, options.argument_buffers, options.resource_bindings, &pull_model, &atomic_images, &arraylen_empty);
        }
        g_proto_only = false;
        try w.writeAll("\n");
    }

    // Emit non-entry functions first
    for (func_ids.items) |fid| {
        if (fid == entry_id) continue;
        try emitFunction(&module, &names, &decs, fid, w, aa, false, &out_param_info, &cbuffers, &textures, &storage_buffers, &stage_inputs, &stage_outputs, is_compute_like, options.binding_shift, options.argument_buffers, options.resource_bindings, &pull_model, &atomic_images, &arraylen_empty);
    }
    // Emit entry function last
    try emitFunction(&module, &names, &decs, entry_id, w, aa, true, &out_param_info, &cbuffers, &textures, &storage_buffers, &stage_inputs, &stage_outputs, is_compute_like, options.binding_shift, options.argument_buffers, options.resource_bindings, &pull_model, &atomic_images, &arraylen_buf_index);
    output_owned = false;
    return output.toOwnedSlice(alloc);
}

// ---- Parser ----
fn parseModule(alloc: std.mem.Allocator, words: []const u32) !ParsedModule {
    if (words.len < 5) return error.InvalidSpirv;
    if (words[0] != spirv.MAGIC) return error.InvalidSpirvMagic;
    var instructions = std.ArrayList(Instruction).initCapacity(alloc, words.len / 4) catch return error.OutOfMemory;
    errdefer instructions.deinit(alloc);
    // Reject an absurd id bound before allocating id_defs: a hostile ~4-billion
    // bound would make this allocation and its zero-fill hang. A real module
    // never has more result ids than words.
    const bound = if (words.len > 3) words[3] else 0;
    if (bound > words.len) return error.InvalidSpirv;
    const id_defs = try alloc.alloc(?usize, bound);
    // The parse loop below can reject a malformed instruction; without this the
    // id table leaks on every rejected module.
    errdefer alloc.free(id_defs);
    @memset(id_defs, null);
    var i: usize = 5;
    while (i < words.len) {
        const hw = words[i];
        const wc: u16 = @intCast(hw >> 16);
        const oc: u16 = @truncate(hw & 0xFFFF);
        if (wc == 0) return error.InvalidSpirv;
        if (i + wc > words.len) return error.InvalidSpirvTruncated;
        const op: spirv.Op = @enumFromInt(oc);
        // Reject an instruction shorter than its opcode's spec minimum, so the
        // emit arms below never index past the end of `inst.words`. (Shared
        // table, see common.minWordCount.)
        if (common.minWordCount(op)) |min| {
            if (wc < min) return error.InvalidSpirvTruncated;
        }
        const iw = words[i .. i + wc];
        if (resultIdFromOp(op, iw)) |id| {
            if (id < bound) id_defs[id] = instructions.items.len;
        }
        instructions.append(alloc, .{ .op = op, .words = iw }) catch return error.OutOfMemory;
        i += wc;
    }
    // Not `catch instructions.items`: that hands back the backing buffer, whose
    // capacity is larger than items.len, and ParsedModule.deinit would then free
    // a slice of the wrong length.
    const owned = instructions.toOwnedSlice(alloc) catch return error.OutOfMemory;
    var module = ParsedModule{ .instructions = owned, .id_defs = id_defs };
    for (module.instructions) |inst| {
        if (inst.op == .EntryPoint and inst.words.len > 2) {
            if (module.entry_point_id == null) {
                module.execution_model = @enumFromInt(inst.words[1]);
                module.entry_point_id = inst.words[2];
            }
        }
        if (inst.op == .ExecutionMode and inst.words.len >= 3) {
            const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]);
            if (mode == .LocalSize and inst.words.len >= 6) module.local_size = .{ inst.words[3], inst.words[4], inst.words[5] };
        }
        // OpExecutionModeId (331): id-operand form. LocalSizeId here carries spec-constant
        // RESULT IDs (the valid form for compute). Resolve via common.specConstantDefault
        // (evaluates OpSpecConstantOp, e.g. SC*2, incl. plain OpConstant operands) so the
        // workgroup size is the intended one instead of silently 1x1x1. MSL had NO
        // LocalSizeId handling at all before this (even plain OpSpecConstant was ignored).
        // (e54.4.8 cross-backend S3; #514 fixed WGSL.)
        if (inst.op == .ExecutionModeId and inst.words.len >= 6) {
            const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]);
            if (mode == .LocalSizeId) module.local_size = .{
                common.specConstantDefault(&module, inst.words[3], 1),
                common.specConstantDefault(&module, inst.words[4], 1),
                common.specConstantDefault(&module, inst.words[5], 1),
            };
        }
    }
    return module;
}

fn findEntryPoint(module: *const ParsedModule, name: []const u8) ?u32 {
    for (module.instructions) |inst| {
        if (inst.op == .EntryPoint and inst.words.len > 3) {
            const bytes = std.mem.sliceAsBytes(inst.words[3..]);
            var len: usize = 0;
            while (len < bytes.len) : (len += 1) {
                if (bytes[len] == 0) break;
            }
            if (std.mem.eql(u8, bytes[0..len], name)) return inst.words[2];
        }
    }
    return null;
}

fn resultIdFromOp(op: spirv.Op, words: []const u32) ?u32 {
    return switch (op) {
        .TypeVoid, .TypeBool, .TypeInt, .TypeFloat, .TypeVector, .TypeMatrix, .TypeImage, .TypeSampler, .TypeSampledImage, .TypeArray, .TypeRuntimeArray, .TypeStruct, .TypePointer, .TypeFunction, .TypeForwardPointer, .TypeAccelerationStructureKHR, .TypeRayQueryKHR, .TypeTensorARM => if (words.len > 1) words[1] else null,
        .ConstantTrue, .ConstantFalse, .Constant, .ConstantComposite, .ConstantNull, .SpecConstant, .SpecConstantTrue, .SpecConstantFalse, .SpecConstantComposite, .SpecConstantOp, .Undef => if (words.len > 2) words[2] else null,
        .Variable, .Function, .FunctionParameter => if (words.len > 2) words[2] else null,
        .Load, .AccessChain, .CompositeConstruct, .CompositeExtract, .CompositeInsert, .VectorShuffle, .SampledImage, .ImageSampleImplicitLod, .ImageSampleExplicitLod, .ImageFetch, .ImageGather, .ImageQuerySizeLod, .ImageQuerySize, .ImageTexelPointer, .FunctionCall, .CopyObject, .Phi, .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU, .UConvert, .SConvert, .FConvert, .Bitcast, .SNegate, .FNegate, .IAdd, .FAdd, .ISub, .FSub, .IMul, .FMul, .UDiv, .SDiv, .FDiv, .UMod, .SRem, .SMod, .FRem, .FMod, .VectorTimesScalar, .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix, .Dot, .Transpose, .OuterProduct, .Select, .LogicalOr, .LogicalAnd, .LogicalNot, .IEqual, .INotEqual, .UGreaterThan, .SGreaterThan, .UGreaterThanEqual, .SGreaterThanEqual, .ULessThan, .SLessThan, .ULessThanEqual, .SLessThanEqual, .FOrdEqual, .FOrdNotEqual, .FOrdLessThan, .FOrdGreaterThan, .FOrdLessThanEqual, .FOrdGreaterThanEqual, .FUnordEqual, .FUnordNotEqual, .FUnordLessThan, .FUnordGreaterThan, .FUnordLessThanEqual, .FUnordGreaterThanEqual, .ShiftRightLogical, .ShiftRightArithmetic, .ShiftLeftLogical, .BitwiseOr, .BitwiseXor, .BitwiseAnd, .Not, .BitReverse, .BitCount, .BitFieldInsert, .BitFieldSExtract, .BitFieldUExtract, .IsNan, .IsInf, .All, .Any, .DPdx, .DPdy, .Fwidth, .DPdxFine, .DPdyFine, .FwidthFine, .DPdxCoarse, .DPdyCoarse, .FwidthCoarse, .VectorExtractDynamic, .ExtInst, .OpImage, .AtomicIAdd, .AtomicISub, .AtomicExchange, .AtomicSMin, .AtomicUMin, .AtomicSMax, .AtomicUMax, .AtomicAnd, .AtomicOr, .AtomicXor, .AtomicCompareExchange, .AtomicFAddEXT, .ImageSampleDrefImplicitLod, .ImageSampleDrefExplicitLod, .ImageSampleProjImplicitLod, .ImageSampleProjExplicitLod, .ImageSampleProjDrefImplicitLod, .ImageSampleProjDrefExplicitLod, .ImageDrefGather, .ImageQueryLod, .ImageQueryLevels, .ImageQuerySamples, .ImageRead, .ArrayLength => if (words.len > 2) words[2] else null,
        // #subgroup-operand: subgroup ops define a result at words[2]; without
        // this the result was never pre-named, so the emit handler's `orelse "v"`
        // fallback collided with a user variable and the downstream store dropped
        // the value. Mirrors common.resultIdFromOp.
        .GroupNonUniformElect, .GroupNonUniformAll, .GroupNonUniformAny, .GroupNonUniformAllEqual, .GroupNonUniformBroadcast, .GroupNonUniformBroadcastFirst, .GroupNonUniformBallot, .GroupNonUniformIAdd, .GroupNonUniformFAdd, .GroupNonUniformIMul, .GroupNonUniformFMul, .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin, .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax, .GroupNonUniformBitwiseAnd, .GroupNonUniformBitwiseOr, .GroupNonUniformBitwiseXor, .GroupNonUniformLogicalAnd, .GroupNonUniformLogicalOr, .GroupNonUniformShuffle, .GroupNonUniformShuffleXor, .GroupNonUniformShuffleUp, .GroupNonUniformShuffleDown, .SubgroupAllKHR, .SubgroupAnyKHR => if (words.len > 2) words[2] else null,
        else => null,
    };
}

// ---- Collection passes ----
fn collectNames(alloc: std.mem.Allocator, m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8)) void {
    var counter: u32 = 0;
    // Reverse index of every name handed out so far (OpName debug names, composite
    // literals, aliases, counter temps). The counter pass below must NOT reuse a
    // spelling another id already holds: an input can carry OpName "v90" (glslang
    // preserves zioshade's own GLSL names on a round-trip), and giving a second id
    // the same spelling made both declare `v90` in one function scope -> Metal
    // redefinition error, invalid MSL (graphicsfuzz_028 round-trip).
    var used_names = std.StringHashMap(void).init(alloc);
    defer used_names.deinit();
    {
        var seedIt = names.iterator();
        while (seedIt.next()) |e| used_names.put(e.value_ptr.*, {}) catch {};
    }
    for (m.instructions) |inst| {
        if (inst.op == .Name and inst.words.len >= 3) {
            const id = inst.words[1];
            const ns = parseLitStr(alloc, inst.words[2..]) catch continue;
            const san = sanitizeName(alloc, ns) catch {
                names.put(id, ns) catch {};
                used_names.put(ns, {}) catch {};
                continue;
            };
            alloc.free(ns);
            names.put(id, san) catch {};
            used_names.put(san, {}) catch {};
        }
        if (inst.op == .Constant and inst.words.len > 3) {
            const rid = inst.words[2];
            const ti = getDef(m, inst.words[1]);
            if (ti) |t| {
                const lit = constantLiteral(alloc, t, inst.words[3..]) catch continue;
                if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                continue;
            }
        }
        if (inst.op == .ConstantTrue and inst.words.len > 2) {
            const l = alloc.dupe(u8, "true") catch continue;
            if (names.fetchPut(inst.words[2], l) catch null) |old| alloc.free(old.value);
            continue;
        }
        if (inst.op == .ConstantFalse and inst.words.len > 2) {
            const l = alloc.dupe(u8, "false") catch continue;
            if (names.fetchPut(inst.words[2], l) catch null) |old| alloc.free(old.value);
            continue;
        }
        if ((inst.op == .ConstantNull or inst.op == .Undef) and inst.words.len > 2) {
            // OpConstantNull = the zero value for its type (spirv-opt -O produces
            // these for default/else values). OpUndef is the same idea (a module-scope
            // undef that every emit switch misses -> undeclared at use sites). Resolve
            // both inline to a zero literal so neither gets a sequential `vNN` name.
            // Matches spirv-cross (zero-inits undef).
            const vt = mslType(m, inst.words[1], names, alloc) catch "float";
            const zero: []const u8 = if (vt.len > 0 and vt[vt.len - 1] >= '0' and vt[vt.len - 1] <= '9')
                std.fmt.allocPrint(alloc, "{s}(0)", .{vt}) catch continue
            else if (std.mem.eql(u8, vt, "float") or std.mem.eql(u8, vt, "half"))
                alloc.dupe(u8, "0.0") catch continue
            else if (std.mem.eql(u8, vt, "bool"))
                alloc.dupe(u8, "false") catch continue
            else
                alloc.dupe(u8, "0") catch continue;
            if (names.fetchPut(inst.words[2], zero) catch null) |old| alloc.free(old.value);
            continue;
        }
        if (inst.op == .ConstantComposite and inst.words.len > 3) {
            const rid = inst.words[2];
            const ti = getDef(m, inst.words[1]);
            if (ti) |t| {
                if (t.op == .TypeVector) {
                    const constituents = inst.words[3..];
                    var all_same = true;
                    if (constituents.len > 1) {
                        const first = constituents[0];
                        for (constituents[1..]) |c| {
                            if (c != first) {
                                all_same = false;
                                break;
                            }
                        }
                    }
                    const vt = mslType(m, inst.words[1], names, alloc) catch "float4";
                    if (all_same and constituents.len > 0) {
                        const val = names.get(constituents[0]) orelse "0.0";
                        const lit = std.fmt.allocPrint(alloc, "{s}({s})", .{ vt, val }) catch continue;
                        if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    } else {
                        var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch continue;
                        defer buf.deinit(alloc);
                        buf.print(alloc, "{s}(", .{vt}) catch continue;
                        for (constituents, 0..) |cid, i| {
                            if (i > 0) buf.appendSlice(alloc, ", ") catch continue;
                            buf.appendSlice(alloc, names.get(cid) orelse "0.0") catch continue;
                        }
                        buf.appendSlice(alloc, ")") catch continue;
                        const lit = buf.toOwnedSlice(alloc) catch continue;
                        if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    }
                    continue;
                }
                // A STRUCT constant folds to a Metal brace initializer
                // `TypeName{c0, c1, …}` (Metal has no struct call-constructor); a
                // MATRIX constant folds to `floatCxR(col0, col1, …)`. Without this
                // the constant got a bare `vNN` name and was never declared, so its
                // use (`arr[0] = vNN;`, `m * vNN`) referenced an undeclared identifier.
                // Constituents are processed earlier in this in-order pass, so their
                // names (`float3(…)`, scalars) are already resolved.
                if (t.op == .TypeStruct or t.op == .TypeMatrix) {
                    const constituents = inst.words[3..];
                    const tn = mslType(m, inst.words[1], names, alloc) catch continue;
                    const open: []const u8 = if (t.op == .TypeStruct) "{" else "(";
                    const close: []const u8 = if (t.op == .TypeStruct) "}" else ")";
                    var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch continue;
                    defer buf.deinit(alloc);
                    buf.print(alloc, "{s}{s}", .{ tn, open }) catch continue;
                    for (constituents, 0..) |cid, i| {
                        if (i > 0) buf.appendSlice(alloc, ", ") catch continue;
                        buf.appendSlice(alloc, names.get(cid) orelse "0.0") catch continue;
                    }
                    buf.appendSlice(alloc, close) catch continue;
                    const lit = buf.toOwnedSlice(alloc) catch continue;
                    if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    continue;
                }
            }
        }
        if (resultIdFromOp(inst.op, inst.words)) |rid| {
            if (!names.contains(rid)) {
                var name: ?[]const u8 = null;
                while (name == null) {
                    const cand = std.fmt.allocPrint(alloc, "v{}", .{counter}) catch break;
                    counter += 1;
                    if (used_names.contains(cand)) {
                        alloc.free(cand);
                        continue;
                    }
                    used_names.put(cand, {}) catch {};
                    name = cand;
                }
                const nm = name orelse continue;
                names.put(rid, nm) catch {};
            }
        }
    }

    // Deduplicate function-local variable names
    var func_var_ids_msl = std.AutoHashMap(u32, void).init(alloc);
    defer func_var_ids_msl.deinit();
    for (m.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Function) {
                func_var_ids_msl.put(inst.words[2], {}) catch {};
            }
        }
    }
    var msl_fv_name_ids = std.StringHashMap(std.ArrayList(u32)).init(alloc);
    defer {
        var mfit = msl_fv_name_ids.iterator();
        while (mfit.next()) |entry| {
            entry.value_ptr.deinit(alloc);
        }
        msl_fv_name_ids.deinit();
    }
    var mfvniter = func_var_ids_msl.iterator();
    while (mfvniter.next()) |entry| {
        const id = entry.key_ptr.*;
        const name = names.get(id) orelse continue;
        const gop = msl_fv_name_ids.getOrPut(name) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u32).initCapacity(alloc, 2) catch continue;
        }
        gop.value_ptr.append(alloc, id) catch {};
    }
    var msl_fvdniter = msl_fv_name_ids.iterator();
    while (msl_fvdniter.next()) |entry| {
        const mname = entry.key_ptr.*;
        const mids = entry.value_ptr.*;
        if (mids.items.len <= 1) continue;
        for (mids.items, 0..) |mid, mi| {
            if (mi == 0) continue;
            const mnew = std.fmt.allocPrint(alloc, "{s}_{d}", .{ mname, mid }) catch continue;
            names.put(mid, mnew) catch {};
        }
    }
}

fn collectDecorations(alloc: std.mem.Allocator, m: *const ParsedModule, decs: *std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) !void {
    for (m.instructions) |inst| {
        if (inst.op == .Decorate and inst.words.len >= 3) {
            const id = inst.words[1];
            const dec: spirv.Decoration = @enumFromInt(inst.words[2]);
            const extra = if (inst.words.len > 3) inst.words[3..] else &[_]u32{};
            const gop = try decs.getOrPut(id);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(DecorationEntry).empty;
            try gop.value_ptr.append(alloc, .{ .decoration = dec, .extra = extra });
        }
    }
}

/// Collect OpMemberDecorate offset decorations into a map: (struct_id, member_index) -> byte_offset.
fn collectMemberOffsets(m: *const ParsedModule, offsets: *std.AutoHashMap(MemberKey, u32)) void {
    for (m.instructions) |inst| {
        // OpMemberDecorate: [opcode+count, struct_id, member_index, decoration, extra...]
        if (inst.op == .MemberDecorate and inst.words.len >= 5) {
            const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
            if (dec == .offset) {
                const key = MemberKey{ .struct_id = inst.words[1], .member_index = inst.words[2] };
                offsets.put(key, inst.words[4]) catch {};
            }
        }
    }
}

fn collectResources(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), cb: *std.ArrayList(CbufferDecl), tex: *std.ArrayList(TextureDecl), loose: *std.ArrayList(LooseUniform), img_access: *const std.AutoHashMap(u32, ImageAccess), alloc: std.mem.Allocator) void {
    // In MSL, UBOs and SSBOs share the single [[buffer(N)]] index space, so the
    // synthesized _Globals block must be placed above the max binding over BOTH
    // (a loose uniform colliding with an SSBO at the same slot would alias the
    // same [[buffer(N)]]) (#417).
    var max_buf_binding: ?u32 = null;
    const trackBinding = struct {
        fn f(cur: *?u32, b: u32) void {
            if (cur.* == null or b > cur.*.?) cur.* = b;
        }
    }.f;
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const rt = inst.words[1];
        const rid = inst.words[2];
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        const pi = getDef(m, rt) orelse continue;
        if (pi.op != .TypePointer or pi.words.len < 4) continue;
        const pt = pi.words[3];
        switch (sc) {
            .Uniform => {
                const binding = getDecVal(decs, rid, .binding) orelse 0;
                if (hasDec(decs, pt, .buffer_block)) {
                    // SSBO (Uniform + BufferBlock): shares the MSL buffer index space.
                    trackBinding(&max_buf_binding, binding);
                    continue;
                }
                const set = getDecVal(decs, rid, .descriptor_set) orelse 0;
                // A loose (non-block) uniform points at a scalar/vector/matrix/array,
                // not a struct. Gather it into the synthesized _Globals block and
                // qualify body references as `_Globals_1.<name>` (#417); MSL has no
                // bare global uniform, so an empty per-uniform struct loses the value.
                const pti = getDef(m, pt);
                if (pti == null or pti.?.op != .TypeStruct) {
                    // names.get returns arena-owned bytes that stay valid across the
                    // later names.put (put replaces the map value, it does not free the
                    // old backing bytes), so no dupe is needed (matches HLSL) (#417).
                    const orig = names.get(rid) orelse "u";
                    loose.append(alloc, .{ .name = orig, .type_id = pt }) catch {};
                    const qualified = std.fmt.allocPrint(alloc, "_Globals_1.{s}", .{orig}) catch continue;
                    _ = names.put(rid, qualified) catch {};
                    continue;
                }
                trackBinding(&max_buf_binding, binding);
                // A block instance with no name (`uniform buf0 { ... };` with the instance
                // omitted) is OpName "" -- PRESENT but empty, so `orelse` never fires and
                // cb.name stays empty. That empty name is used for the struct declaration
                // (`struct \n{`, which Metal rejects as an anonymous struct), the parameter
                // type, and every body reference. Synthesize a stable name from the struct
                // type, else the binding, and publish it back into `names` so the
                // declaration and all references agree. Same root fix as GLSL #523; the
                // HLSL twin covers only SSBOs (#474), not UBOs.
                const cb_nm: []const u8 = blk: {
                    if (names.get(rid)) |n| if (n.len > 0) break :blk n;
                    if (names.get(pt)) |tn| if (tn.len > 0) break :blk tn;
                    break :blk std.fmt.allocPrint(alloc, "_ub{d}", .{binding}) catch "_ub";
                };
                _ = names.put(rid, cb_nm) catch {};
                cb.append(alloc, .{ .name = cb_nm, .type_id = pt, .binding = binding, .descriptor_set = set }) catch {};
            },
            .StorageBuffer => {
                // SSBO (SPIR-V 1.3+ storage-class form): shares the MSL buffer
                // index space with UBOs, so track it for _Globals slot selection.
                trackBinding(&max_buf_binding, getDecVal(decs, rid, .binding) orelse 0);
            },
            .UniformConstant => {
                const pei = getDef(m, pt) orelse continue;
                const binding = getDecVal(decs, rid, .binding) orelse 0;
                const set = getDecVal(decs, rid, .descriptor_set) orelse 0;
                const name = names.get(rid) orelse "tex";
                const is_depth = imageTypeIsDepth(m, pei);
                var img = pei;
                if (img.op == .TypeSampledImage and img.words.len > 2) {
                    img = getDef(m, img.words[2]) orelse img;
                }
                const dim: u32 = if (img.op == .TypeImage and img.words.len > 3) img.words[3] else 1;
                const arrayed: bool = img.op == .TypeImage and img.words.len > 5 and img.words[5] == 1;
                const ms: bool = img.op == .TypeImage and img.words.len > 6 and img.words[6] == 1;
                // A bare OpTypeImage with Sampled==2 is a STORAGE image (read/write/atomic,
                // no combined sampler). It takes an MSL `access::` qualifier driven by its
                // actual OpImageRead/OpImageWrite usage; sampled images keep default access.
                const is_storage = img.op == .TypeImage and img.words.len > 7 and img.words[7] == 2;
                // Access qualifier from actual OpImageRead/OpImageWrite usage. Metal's
                // get_width() (used by spvImage2DAtomicCoord) is a size query valid on ANY
                // access qualifier — so an atomic image that is ALSO directly written takes
                // access::write (matching spirv-cross); a coord-only atomic image has no
                // read/write usage -> empty suffix -> default sample (get_width still works).
                const access_suffix = if (is_storage) mslStorageAccessSuffix(img_access.get(rid) orelse .{}) else "";
                const comp = mslSampledComponent(m, img);
                const msl_type = buildMslTextureType(alloc, is_depth, dim, arrayed, ms, comp, access_suffix);
                switch (pei.op) {
                    .TypeSampledImage => {
                        tex.append(alloc, .{ .name = name, .binding = binding, .descriptor_set = set, .is_depth = is_depth, .dim = dim, .arrayed = arrayed, .msl_type = msl_type, .var_id = rid, .is_storage = is_storage }) catch {};
                    },
                    .TypeImage => {
                        tex.append(alloc, .{ .name = name, .binding = binding, .descriptor_set = set, .is_depth = is_depth, .dim = dim, .arrayed = arrayed, .msl_type = msl_type, .var_id = rid, .is_storage = is_storage }) catch {};
                    },
                    .TypeSampler => {
                        // Bare GLSL sampler (GL_EXT_samplerless_texture_functions) -- a
                        // separate sampler resource. is_storage=true reuses the
                        // "no paired Smplr" path; msl_type="sampler" types it; the
                        // wrapper switches [[texture]]->[[sampler]]. combined-texture-sampler.
                        tex.append(alloc, .{ .name = name, .binding = binding, .descriptor_set = set, .msl_type = "sampler", .var_id = rid, .is_storage = true }) catch {};
                    },
                    else => {},
                }
            },
            .PushConstant => {
                // #483: a push_constant block is a plain uniform buffer in MSL —
                // `constant T& name [[buffer(N)]]`, threaded exactly like a UBO.
                // Push constants carry no Binding decoration, so give it a buffer
                // slot (0 by default; the loose/_Globals slot picker below tracks
                // it). Named struct blocks only: an anonymous push block would need
                // _Globals-style bare-member qualification (left as a follow-up).
                const pti = getDef(m, pt);
                if (pti != null and pti.?.op == .TypeStruct) {
                    if (names.get(rid)) |nm| {
                        const binding = getDecVal(decs, rid, .binding) orelse 0;
                        const set = getDecVal(decs, rid, .descriptor_set) orelse 0;
                        trackBinding(&max_buf_binding, binding);
                        cb.append(alloc, .{ .name = nm, .type_id = pt, .binding = binding, .descriptor_set = set }) catch {};
                    }
                }
            },
            else => {},
        }
    }
    // Represent the synthesized default block as one cbuffer entry so it flows
    // through the param/call/argument-buffer plumbing like a normal UBO. type_id
    // 0 marks it as backed by `loose` rather than a SPIR-V struct (#417).
    if (loose.items.len > 0) {
        // Place _Globals above the max binding over ALL uniform and storage
        // buffers so it never aliases another buffer's [[buffer(N)]] slot (#417).
        var b: u32 = if (max_buf_binding) |mb| mb + 1 else 0;
        for (cb.items) |c| {
            if (c.binding >= b) b = c.binding + 1;
        }
        // descriptor_set = 0 is deliberate: _Globals is a synthetic host-bound
        // block with no SPIR-V descriptor set of its own, so it lands in set 0.
        cb.append(alloc, .{ .name = "_Globals", .type_id = 0, .binding = b, .descriptor_set = 0 }) catch {};
    }
}

/// Collect location-decorated fragment Input variables into `inputs`, sorted
/// ascending by Location (matching spirv-cross --msl `main0_in` field order).
///
/// Excluded (kept on their existing paths, NOT placed in `main0_in`):
///   - Built-in inputs (gl_FragCoord etc.): `built_in` decoration present.
///   - Struct-typed inputs (per-vertex interface blocks): out of scope here.
///   - Inputs without a Location decoration (nothing to bind to `[[user(locnN)]]`).
/// True when some non-entry function calls a callee that is emitted LATER in
/// `func_ids` order (a forward reference / mutual recursion), so C prototypes are
/// needed before the bodies. Scans each non-entry function's instruction range
/// for OpFunctionCall and compares emission order. (#480)
fn needsForwardDecls(m: *const ParsedModule, func_ids: []const u32, entry_id: u32) bool {
    for (func_ids, 0..) |fid, order| {
        if (fid == entry_id) continue;
        var in_fn = false;
        for (m.instructions) |inst| {
            if (inst.op == .Function and inst.words.len > 2) {
                in_fn = inst.words[2] == fid;
                continue;
            }
            if (!in_fn) continue;
            if (inst.op == .FunctionEnd) {
                in_fn = false;
                continue;
            }
            if (inst.op == .FunctionCall and inst.words.len > 3) {
                const callee = inst.words[3];
                for (func_ids, 0..) |cid, corder| {
                    if (cid == callee and corder > order) return true;
                }
            }
        }
    }
    return false;
}

/// Metal reserved identifiers that are NOT GLSL/SPIR-V keywords, so a SPIR-V
/// stage input can legitimately be named one of them (e.g. `vertex`). Using such a
/// name as an MSL field/variable is a hard Metal compile error ("'vertex' is a
/// function qualifier"), so append `_`. This is the MSL analog of spirv-cross's
/// identifier-collision avoidance (it appends the location, e.g. `vertex0`). The
/// list is limited to Metal-specific keywords: GLSL/C keywords can never appear as
/// SPIR-V names (the frontend rejects them), and MSL attribute values like
/// `color`/`position` are valid as identifiers.
/// MSL type of the single fragment color output (Location 0), for typing the
/// `main0_out` color attachment + the impl's output ref param. Defaults to float4.
/// Only invoked on the single-color path now (isSingleColorFragOutput), so the
/// non-default path is a single scalar/vector color (out int/float/vec2/vec3) -- the
/// hardcoded float4 was silent-wrong (for-loop-init `out int`, matrix-conversion `out vec3`).
fn fragmentOutputMslType(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), alloc: std.mem.Allocator) []const u8 {
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Output) continue;
        const rid = inst.words[2];
        const loc = getDecVal(decs, rid, .location) orelse continue;
        if (loc != 0) continue;
        const ptr = getDef(m, inst.words[1]) orelse return "float4";
        if (ptr.op != .TypePointer or ptr.words.len < 4) return "float4";
        const pti = getDef(m, ptr.words[3]) orelse return "float4";
        if (pti.op != .TypeFloat and pti.op != .TypeInt and pti.op != .TypeVector) return "float4";
        return mslType(m, ptr.words[3], names, alloc) catch "float4";
    }
    return "float4";
}

/// True if any multisampled STORAGE image (OpTypeImage Multisampled=1 + Sampled=2) is
/// BOTH read and written. Metal texture2d_ms rejects access::read_write (an MS texture
/// object is read OR write, not both), so such an image cannot be one Metal texture --
/// honest-error it (genuinely Metal-limited, not a zioshade gap). image-ms.
fn mslHasReadWriteMSStorageImage(m: *const ParsedModule, img_access: *const std.AutoHashMap(u32, ImageAccess)) bool {
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 3) continue;
        const ptr = getDef(m, inst.words[1]) orelse continue;
        if (ptr.op != .TypePointer or ptr.words.len < 4) continue;
        const img = getDef(m, ptr.words[3]) orelse continue;
        if (img.op != .TypeImage or img.words.len <= 7) continue;
        if (img.words[6] == 1 and img.words[7] == 2) {
            if (img_access.get(inst.words[2])) |acc| {
                if (acc.read and acc.write) return true;
            }
        }
    }
    return false;
}

fn mslSanitizeName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const reserved = [_][]const u8{
        // Function qualifiers (pipeline stages).
        "vertex",  "fragment",               "kernel", "compute",     "mesh",     "object",      "primitive",      "ray",       "payload",
        // Address spaces.
        "device",  "constant",               "thread", "threadgroup", "ray_data", "object_data", "primitive_data", "mesh_data", "imageblock",
        "visible", "threadgroup_imageblock",
    };
    for (reserved) |kw| {
        if (std.mem.eql(u8, name, kw)) return std.fmt.allocPrint(alloc, "{s}_", .{name});
    }
    return name;
}

/// Number of location slots a type consumes in a flattened stage-in (for computing
/// per-member locations of an interface block). A scalar/vector is 1 slot; a struct is
/// the sum of its members' slots (recursive). (multiple-struct-flattening: a Foo{vec4,vec4}
/// member occupies 2 locations, so the next member starts at +2, not +1.)
fn typeLocFootprint(m: *const ParsedModule, type_id: u32) u32 {
    const t = getDef(m, type_id) orelse return 1;
    if (t.op == .TypeStruct) {
        var sum: u32 = 0;
        var i: usize = 2;
        while (i < t.words.len) : (i += 1) sum += typeLocFootprint(m, t.words[i]);
        return sum;
    }
    return 1;
}

fn collectStageInputs(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), inputs: *std.ArrayList(StageInputDecl), block_flat: *std.AutoHashMap(u64, []const u8), alloc: std.mem.Allocator) void {
    // #500 recursive flatten: walk a flattened Input struct's members to scalar/
    // vector LEAVES, emitting one StageInputDecl per leaf with a deterministic
    // dotted name `<prefix>_<member>` (so a leaf at path [m0,m1,...] of block
    // var V is `V_m0_m1_...`). Metal's [[stage_in]] rejects struct-typed fields,
    // so nested struct members must be flattened to leaves. `prefix` already
    // carries the var name + the ancestor member names; `loc` is the accumulated
    // Location for this member.
    const recurse = struct {
        fn run(mod: *const ParsedModule, ins: *std.ArrayList(StageInputDecl), al: std.mem.Allocator, var_id: u32, prefix: []const u8, type_id: u32, loc: u32, component: ?u32) void {
            const td = getDef(mod, type_id) orelse {
                ins.append(al, .{ .var_id = var_id, .name = mslSanitizeName(al, prefix) catch prefix, .type_id = type_id, .location = loc, .component = component }) catch {};
                return;
            };
            if (td.op == .TypeStruct and td.words.len > 2) {
                const nmembers: u32 = @intCast(td.words.len - 2);
                var mi: u32 = 0;
                var offset = loc;
                while (mi < nmembers) : (mi += 1) {
                    const cmtype = td.words[mi + 2];
                    var nbuf: [32]u8 = undefined;
                    const cmname = getMemberName(mod, type_id, mi, &nbuf);
                    const cprefix = std.fmt.allocPrint(al, "{s}_{s}", .{ prefix, cmname }) catch continue;
                    const cmloc = memberDecVal(mod, type_id, mi, .location) orelse offset;
                    // Component: a member's own Component wins, else inherit (so a
                    // component-packed leaf under a struct member keeps it).
                    const cmcomp = memberDecVal(mod, type_id, mi, .component) orelse component;
                    run(mod, ins, al, var_id, cprefix, cmtype, cmloc, cmcomp);
                    offset = cmloc + typeLocFootprint(mod, cmtype);
                }
                return;
            }
            ins.append(al, .{ .var_id = var_id, .name = mslSanitizeName(al, prefix) catch prefix, .type_id = type_id, .location = loc, .component = component }) catch {};
        }
    };

    // #475: MSL interpolation attribute appended to the fragment stage-in `[[user(locnN)]]`.
    // Flat-on-FLOAT needs `[[flat]]` (Metal auto-flats only INTEGERS — so glslang's Flat
    // decoration on an integer varying is OMITTED, matching spirv-cross; emitting it broke
    // T15.5). NoPerspective needs `[[center_no_perspective]]`. Vertex stage-in is
    // `[[attribute(N)]]` (fetched, not interpolated) so this is unused there.
    const mslInterpAttr = struct {
        fn forVar(mod: *const ParsedModule, d: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, type_id: u32) []const u8 {
            // #475: MSL composes position (center/centroid/sample) × interp
            // (perspective/no_perspective). Flat has no position variant.
            if (hasDec(d, id, .flat) and !mslElementIsInt(mod, type_id)) return ", flat";
            const no_persp = hasDec(d, id, .no_perspective);
            if (hasDec(d, id, .sample)) return if (no_persp) ", sample_no_perspective" else ", sample_perspective";
            if (hasDec(d, id, .centroid)) return if (no_persp) ", centroid_no_perspective" else ", centroid_perspective";
            if (no_persp) return ", center_no_perspective";
            return "";
        }
    };
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .Input) continue;
        const rid = inst.words[2];
        // Built-ins keep their own [[position]]/builtin path.
        if (hasDec(decs, rid, .built_in)) continue;
        // An interface block (struct-typed Input) may have NO variable-level Location
        // (anonymous block) -- its members have Location via MemberDecorate. Check the
        // type BEFORE requiring a variable Location so such blocks are flattened.
        const pi = getDef(m, inst.words[1]) orelse continue;
        if (pi.op != .TypePointer or pi.words.len < 4) continue;
        const pt = pi.words[3];
        const pti = getDef(m, pt) orelse continue;
        if (pti.op == .TypeStruct) {
            const block_loc = getDecVal(decs, rid, .location) orelse 0;
            // #478: interface block `layout(location=L) in Block { members } vin;`.
            // Metal stage-in has no nested-struct fields, so FLATTEN each member
            // into its own `T <inst>_<member> [[user(locnK)]]` field with per-member
            // location (base+index, or an explicit member Location) and
            // interpolation. buildAccessExpr rewrites `vin.member` to
            // `in.<inst>_<member>` via block_flat.
            const inst_name = names.get(rid) orelse "vin";
            // Stash the ORIGINAL var name under the sentinel key so the access
            // emitters / load reconstruction can recover it after the body-emit
            // rename clobbers names[rid] = "in.<last-leaf>" (#500 recursive).
            block_flat.put(blockFlatKey(rid, FLAT_VAR_NAME_MEMBER), inst_name) catch {};
            const nmembers: u32 = @intCast(pti.words.len - 2);
            var mi: u32 = 0;
            var offset = block_loc; // cumulative location: a struct-typed member occupies its footprint
            while (mi < nmembers) : (mi += 1) {
                const mtype = pti.words[mi + 2];
                var nbuf: [32]u8 = undefined;
                const mname = getMemberName(m, pt, mi, &nbuf);
                const child_prefix = std.fmt.allocPrint(alloc, "{s}_{s}", .{ inst_name, mname }) catch continue;
                const mloc = memberDecVal(m, pt, mi, .location) orelse offset;
                // Mark this top-level member as flattened (detection for
                // buildAccessExpr / load reconstruction). The value is unused for
                // naming now -- readers build leaf names deterministically.
                block_flat.put(blockFlatKey(rid, mi), child_prefix) catch {};
                // Recurse to scalar/vector leaves (handles nested structs). Pass
                // the member's Component (component packing on a block member).
                recurse.run(m, inputs, alloc, rid, child_prefix, mtype, mloc, memberDecVal(m, pt, mi, .component));
                offset = mloc + typeLocFootprint(m, mtype);
            }
            continue;
        }
        // Non-struct Input: must have an explicit Location to map to [[user(locnN)]].
        const loc = getDecVal(decs, rid, .location) orelse continue;
        const name = names.get(rid) orelse continue;
        const safe = mslSanitizeName(alloc, name) catch name;
        inputs.append(alloc, .{ .var_id = rid, .name = safe, .type_id = pt, .location = loc, .component = getDecVal(decs, rid, .component), .interp = mslInterpAttr.forVar(m, decs, rid, pt) }) catch {};
    }
    const SortCtx = struct {
        fn lessThan(_: void, a: StageInputDecl, b: StageInputDecl) bool {
            return a.location < b.location;
        }
    };
    std.sort.insertion(StageInputDecl, inputs.items, {}, SortCtx.lessThan);
}

// #471 — gl_PerVertex interface-block support (external glslang/shaderc SPIR-V), the
// MSL analogue of the HLSL helpers. Mirrors the already-correct WGSL backend.

/// BuiltIn decorating member `member_idx` of `struct_id`, or null if undecorated.
fn mslMemberBuiltin(m: *const ParsedModule, struct_id: u32, member_idx: u32) ?spirv.BuiltIn {
    for (m.instructions) |inst| {
        if (inst.op != .MemberDecorate or inst.words.len < 5) continue;
        if (inst.words[1] != struct_id or inst.words[2] != member_idx) continue;
        if (@as(spirv.Decoration, @enumFromInt(inst.words[3])) != .built_in) continue;
        return @enumFromInt(inst.words[4]);
    }
    return null;
}

/// If `var_id` is an Output var whose pointee struct has member 0 decorated
/// BuiltIn Position, returns that struct type id — glslang's gl_PerVertex Block.
fn perVertexBlockStructType(m: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), var_id: u32) ?u32 {
    const vdef = getDef(m, var_id) orelse return null;
    if (vdef.op != .Variable or vdef.words.len < 4) return null;
    if (@as(spirv.StorageClass, @enumFromInt(vdef.words[3])) != .Output) return null;
    const ptr = getDef(m, vdef.words[1]) orelse return null;
    if (ptr.op != .TypePointer or ptr.words.len < 4) return null;
    const sty = ptr.words[3];
    const sdef = getDef(m, sty) orelse return null;
    if (sdef.op != .TypeStruct) return null;
    if (mslMemberBuiltin(m, sty, 0)) |mbi| {
        if (mbi == .position) return sty;
    }
    // Name fallback: the frontend does not decorate gl_PerVertex members BuiltIn,
    // so detect the block by its reserved struct name (mirrors the GLSL #471 fix).
    if (names.get(sty)) |sname| {
        if (std.mem.eql(u8, sname, "gl_PerVertex")) return sty;
    }
    return null;
}

/// True if member `member_idx` of block var `var_id` is written (an
/// OpAccessChain <var_id> <const member_idx> result is an OpStore target).
fn perVertexMemberWritten(m: *const ParsedModule, var_id: u32, member_idx: u32) bool {
    for (m.instructions) |inst| {
        if (inst.op != .AccessChain or inst.words.len < 5 or inst.words[3] != var_id) continue;
        const idx_def = getDef(m, inst.words[4]) orelse continue;
        if (idx_def.op != .Constant or idx_def.words.len < 4 or idx_def.words[3] != member_idx) continue;
        for (m.instructions) |s| {
            if (s.op == .Store and s.words.len >= 2 and s.words[1] == inst.words[2]) return true;
        }
    }
    return false;
}

/// #472: the SPIR-V BuiltIn value for FragStencilRefEXT (SPV_EXT_shader_stencil_export).
/// Unnamed in the BuiltIn enum (rare extension); builtinOf returns the raw literal.
const FRAG_STENCIL_REF_EXT: u32 = 5014;

/// #472: gl_FragStencilRefARB is a fragment stencil-ref output. zioshade's GLSL
/// frontend does NOT decorate it with a BuiltIn (it is an extension builtin), so the
/// MSL backend detects it by NAME — the same approach the WGSL backend uses. Metal's
/// `[[stencil]]` output represents it.
fn isFragStencilRefName(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "FragStencilRef") != null;
}

/// #472: collect a FRAGMENT's Output variables, classified into the Metal-
/// representable kinds (color / frag_depth / sample_mask / stencil_ref). Struct-typed
/// outputs are skipped here (they remain unrepresentable). The list is NOT sorted:
/// callers place color outputs in main0_out in Location order, with builtins after,
/// matching spirv-cross --msl (which emits colors by location, then depth/sample_mask).
fn collectFragmentOutputs(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    outputs: *std.ArrayList(FragOutput),
    alloc: std.mem.Allocator,
) void {
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Output) continue;
        const rid = inst.words[2];
        const pi = getDef(m, inst.words[1]) orelse continue;
        if (pi.op != .TypePointer or pi.words.len < 4) continue;
        const pt = pi.words[3];
        const pti = getDef(m, pt) orelse continue;
        // Struct-typed outputs are out of scope (not representable as one main0_out field).
        if (pti.op == .TypeStruct) continue;
        const name = names.get(rid) orelse continue;

        if (builtinOf(decs, rid)) |bi| {
            const kind: ?FragOutputKind = switch (bi) {
                @intFromEnum(spirv.BuiltIn.frag_depth) => .frag_depth,
                @intFromEnum(spirv.BuiltIn.sample_mask) => .sample_mask,
                FRAG_STENCIL_REF_EXT => .stencil_ref,
                else => null, // genuinely-unrepresentable output builtin (see hasUnsupportedFragOutput)
            };
            if (kind) |k| {
                outputs.append(alloc, .{ .var_id = rid, .name = name, .type_id = pt, .kind = k }) catch {};
            }
            continue;
        }
        // gl_FragStencilRefARB: an extension builtin the frontend does not decorate, so
        // detect it by name (mirrors the WGSL backend). It has no Location.
        if (isFragStencilRefName(name)) {
            outputs.append(alloc, .{ .var_id = rid, .name = name, .type_id = pt, .kind = .stencil_ref }) catch {};
            continue;
        }
        // A color attachment. zioshade's frontend does NOT assign a Location to a single
        // undecorated output (the common shadertoy/gl_FragColor case) — default it to 0
        // (Metal's [[color(0)]] default), matching the legacy hardcoded path.
        const loc = getDecVal(decs, rid, .location) orelse 0;
        const idx = getDecVal(decs, rid, .index);
        outputs.append(alloc, .{ .var_id = rid, .name = name, .type_id = pt, .kind = .color, .location = loc, .index = idx }) catch {};
    }
}

/// #472: true if the fragment has a GENUINELY Metal-unrepresentable Output — a struct-
/// typed output, or an output builtin the multi-field path does not map (anything other
/// than FragDepth/SampleMask/FragStencilRefEXT). These cannot become a valid main0_out
/// field, so honest-error them. A location-less non-builtin output is NOT unsupported:
/// it defaults to [[color(0)]] (the common single-color case), matching the legacy path.
fn hasUnsupportedFragOutput(m: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) bool {
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Output) continue;
        const rid = inst.words[2];
        if (builtinOf(decs, rid)) |bi| {
            const supported = (bi == @intFromEnum(spirv.BuiltIn.frag_depth)) or
                (bi == @intFromEnum(spirv.BuiltIn.sample_mask)) or (bi == FRAG_STENCIL_REF_EXT);
            if (!supported) return true;
            continue;
        }
        // gl_FragStencilRefARB (by name) is supported ([[stencil]]).
        if (names.get(rid)) |nm| {
            if (isFragStencilRefName(nm)) continue;
        }
        // A struct-typed output cannot be one main0_out field (not yet flattened).
        const pi = getDef(m, inst.words[1]) orelse continue;
        if (pi.op == .TypePointer and pi.words.len >= 4) {
            if (getDef(m, pi.words[3])) |pti| {
                if (pti.op == .TypeStruct) return true;
            }
        }
    }
    return false;
}

/// #472: the MSL `[[depth(...)]]` qualifier for the FragDepth output, derived from the
/// entry function's ExecutionMode. DepthGreater -> depth(greater), DepthLess ->
/// depth(less), otherwise depth(any) (incl. DepthUnchanged and the no-layout default).
fn fragmentDepthAttribute(m: *const ParsedModule, entry_id: u32) []const u8 {
    for (m.instructions) |inst| {
        if (inst.op != .ExecutionMode or inst.words.len < 3) continue;
        if (inst.words[1] != entry_id) continue;
        const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]);
        if (mode == .DepthGreater) return "depth(greater)";
        if (mode == .DepthLess) return "depth(less)";
    }
    return "depth(any)";
}

/// Fragment shader interlock (GL_ARB_fragment_shader_interlock / SPV_EXT_fragment_shader_interlock):
/// true when the entry point declares one of the pixel/sample interlock execution modes.
/// Metal has no explicit begin/end interlock ops — it models interlock by annotating the
/// storage resources the fragment writes with `[[raster_order_group(0)]]` (the rasterizer
/// then serializes accesses). The Op{Begin,End}InvocationInterlockEXT ops become no-ops.
/// Matches spirv-cross, which emits raster_order_group(0) on device buffers / writable
/// textures and drops the ops entirely.
fn fragmentHasInterlock(m: *const ParsedModule, entry_id: u32) bool {
    for (m.instructions) |inst| {
        if (inst.op != .ExecutionMode or inst.words.len < 3) continue;
        if (inst.words[1] != entry_id) continue;
        const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]);
        switch (mode) {
            .PixelInterlockOrderedEXT,
            .PixelInterlockUnorderedEXT,
            .SampleInterlockOrderedEXT,
            .SampleInterlockUnorderedEXT,
            => return true,
            else => {},
        }
    }
    return false;
}

/// #472: the Metal type string for a fragment output field. gl_SampleMask is int[1] in
/// SPIR-V but a scalar uint [[sample_mask]] in Metal; FragStencilRefEXT is int in SPIR-V
/// and Metal's [[stencil]] takes uint. Color/FragDepth keep the SPIR-V pointee type.
fn fragOutputMslType(m: *const ParsedModule, o: FragOutput, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) []const u8 {
    if (o.kind == .sample_mask) return "uint";
    if (o.kind == .stencil_ref) return "uint";
    return mslType(m, o.type_id, names, alloc) catch "float4";
}

/// #472: true if the fragment takes the SINGLE-color hardcoded path (exactly one Location-
/// 0 color output, no dual-source Index, and NO builtin outputs). This is the common case
/// (1416+ corpus shaders); it must stay byte-identical, so the existing emission is taken
/// unchanged. Anything else (MRT, FragDepth, SampleMask, stencil, dual-source) goes through
/// the new multi-field main0_out path.
fn isSingleColorFragOutput(outputs: []const FragOutput) bool {
    // 0 outputs: no color attachment. This stays on the legacy single path so the
    // decision sites upstream can distinguish it: with NO Output variables at all
    // the entry is a `fragment void` function (no main0_out, nothing written - an
    // earlier empty-main0_out attempt regressed demote-to-helper / image-query /
    // partial-write-preserve validity); with an unrepresentable Output (struct-
    // typed / unknown builtin) the old default `float4 _fragColor [[color(0)]]`
    // fallback keeps the emission Metal-valid.
    if (outputs.len == 0) return true;
    if (outputs.len != 1) return false;
    const o = outputs[0];
    return o.kind == .color and o.location == 0 and o.index == null;
}

/// Collect vertex Output variables into `outputs`, ordered to match
/// spirv-cross --msl `main0_out` field order: user varyings sorted ascending
/// by Location FIRST, then `gl_Position` (BuiltIn Position) appended LAST.
///
/// Excluded (NOT placed in `main0_out`):
///   - Built-in outputs other than Position (gl_PointSize → PointSize,
///     gl_ClipDistance → ClipDistance, gl_CullDistance, gl_Layer, ...). These
///     need their own MSL attributes ([[point_size]], [[clip_distance]], ...)
///     and threading; emitting them as plain user fields would be silent-wrong,
///     so this pass leaves them out entirely (documented follow-up).
///   - Struct-typed outputs (gl_PerVertex interface blocks decomposed by
///     glslang into separate vars — handled per-member, not as a struct here).
///   - Non-position outputs without a Location decoration.
fn collectStageOutputs(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), outputs: *std.ArrayList(StageOutputDecl), alloc: std.mem.Allocator) void {
    var position: ?StageOutputDecl = null;
    var point_size: ?StageOutputDecl = null;
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .Output) continue;
        const rid = inst.words[2];
        const pi = getDef(m, inst.words[1]) orelse continue;
        if (pi.op != .TypePointer or pi.words.len < 4) continue;
        const pt = pi.words[3];
        // Struct-typed outputs (interface blocks) are out of scope for this pass.
        const pti = getDef(m, pt) orelse continue;
        if (pti.op == .TypeStruct) continue;
        const name = names.get(rid) orelse continue;

        // Built-in outputs we map: gl_Position → [[position]], gl_PointSize →
        // [[point_size]]. Others are intentionally skipped (see doc comment).
        if (builtinOf(decs, rid)) |bi| {
            if (bi == @intFromEnum(spirv.BuiltIn.position)) {
                position = .{ .var_id = rid, .name = name, .type_id = pt, .location = 0, .is_position = true };
            } else if (bi == @intFromEnum(spirv.BuiltIn.point_size)) {
                point_size = .{ .var_id = rid, .name = name, .type_id = pt, .location = 0, .is_position = false, .is_point_size = true };
            }
            continue;
        }

        // User varyings must have an explicit Location to map to [[user(locnN)]].
        const loc = getDecVal(decs, rid, .location) orelse continue;
        outputs.append(alloc, .{ .var_id = rid, .name = name, .type_id = pt, .location = loc, .is_position = false }) catch {};
    }
    const SortCtx = struct {
        fn lessThan(_: void, a: StageOutputDecl, b: StageOutputDecl) bool {
            return a.location < b.location;
        }
    };
    std.sort.insertion(StageOutputDecl, outputs.items, {}, SortCtx.lessThan);
    // gl_Position goes after user varyings, then gl_PointSize (matches
    // spirv-cross --msl ordering).
    if (position) |p| outputs.append(alloc, p) catch {};
    if (point_size) |p| outputs.append(alloc, p) catch {};

    // #471: gl_PerVertex Block outputs (glslang/shaderc). gl_Position/gl_PointSize
    // live as member-decorated fields of a struct Output var (skipped above), written
    // via OpAccessChain+OpStore. Promote the written, representable members into
    // main0_out (Position -> [[position]], PointSize -> [[point_size]] — Metal has
    // both). The block var is routed to `out` by the entry (from_block=true); Clip/
    // Cull promotion + honest-error are handled there. Only the FIRST block is taken.
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Output) continue;
        const bvar = inst.words[2];
        const sty = perVertexBlockStructType(m, names, bvar) orelse continue;
        const sdef = getDef(m, sty) orelse continue;
        const nmem: usize = if (sdef.words.len > 2) sdef.words.len - 2 else 0;
        var mi: u32 = 0;
        while (mi < nmem) : (mi += 1) {
            if (!perVertexMemberWritten(m, bvar, mi)) continue;
            var nbuf: [32]u8 = undefined;
            const mname = getMemberName(m, sty, mi, &nbuf);
            // Member decoration first; fallback to member NAME for the frontend gap
            // (the frontend doesn't emit MemberDecorate BuiltIn on gl_PerVertex).
            const mbi = mslMemberBuiltin(m, sty, mi);
            const is_pos = if (mbi) |b| b == .position else std.mem.eql(u8, mname, "gl_Position");
            const is_ps = if (mbi) |b| b == .point_size else std.mem.eql(u8, mname, "gl_PointSize");
            if (!is_pos and !is_ps) continue; // Clip/Cull handled in the entry
            outputs.append(alloc, .{
                .var_id = bvar,
                .name = alloc.dupe(u8, mname) catch continue,
                .type_id = sdef.words[2 + mi],
                .location = 0,
                .is_position = is_pos,
                .is_point_size = is_ps,
                .from_block = true,
            }) catch {};
        }
        break; // one gl_PerVertex block per stage
    }

    // User interface-block outputs (e.g. `out VertexOut { vec4 color; vec3
    // normal; } vout;`) -- struct-typed Output vars skipped at the top of this
    // pass that are NOT the gl_PerVertex builtin block. Flatten their members
    // into main0_out as [[user(locnN)]] fields (location = block location +
    // member index), flagged from_block so the entry renames the block var ->
    // `out` and the body's `vout.member` resolves. Matches spirv-cross --msl.
    // (Simple slot accounting: one location per member; matrix/struct members
    // spanning multiple slots are a known approximation.)
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Output) continue;
        const bvar = inst.words[2];
        if (perVertexBlockStructType(m, names, bvar) != null) continue; // gl_PerVertex, above
        const ptr = getDef(m, inst.words[1]) orelse continue;
        if (ptr.op != .TypePointer or ptr.words.len < 4) continue;
        const sty = ptr.words[3];
        const sdef = getDef(m, sty) orelse continue;
        if (sdef.op != .TypeStruct) continue;
        const nmem: usize = if (sdef.words.len > 2) sdef.words.len - 2 else 0;
        // Block var Location first; if absent, check the first member's Location
        // (some blocks put Location on members, not the block var).
        var block_loc: ?u32 = getDecVal(decs, bvar, .location);
        if (block_loc == null and nmem > 0) {
            for (m.instructions) |inst2| {
                if (inst2.op != .MemberDecorate or inst2.words.len < 5) continue;
                if (inst2.words[1] != sty or inst2.words[2] != 0) continue;
                if (@as(spirv.Decoration, @enumFromInt(inst2.words[3])) == .location) {
                    block_loc = inst2.words[4];
                    break;
                }
            }
        }
        if (block_loc == null) continue;
        const bl: u32 = block_loc.?;
        var mi: u32 = 0;
        while (mi < nmem) : (mi += 1) {
            var nbuf: [32]u8 = undefined;
            const mname = getMemberName(m, sty, mi, &nbuf);
            outputs.append(alloc, .{
                .var_id = bvar,
                .name = alloc.dupe(u8, mname) catch continue,
                .type_id = sdef.words[2 + mi],
                .location = bl + mi,
                .is_position = false,
                .from_block = true,
            }) catch {};
        }
    }
}

/// Return the BuiltIn enum value (as a u32) decorated on `id`, or null if `id`
/// has no BuiltIn decoration. Mirrors the FragCoord check in the fragment entry
/// path (extra[0] carries the BuiltIn literal).
fn builtinOf(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32) ?u32 {
    const dlist = decs.get(id) orelse return null;
    for (dlist.items) |de| {
        if (de.decoration == .built_in and de.extra.len > 0) return de.extra[0];
    }
    return null;
}

/// A SPIR-V Input built-in that maps to an MSL entry-point parameter attribute
/// (e.g. gl_VertexIndex → `uint gl_VertexIndex [[vertex_id]]`). `name` is the
/// identifier the shader body references (kept stable through `names`).
/// `entry_ty` is the MSL type required on the [[attr]] parameter; `impl_ty` is
/// the type the body expects (matches the SPIR-V variable). When they differ
/// (vertex_id/instance_id are uint at the boundary but signed int in the body)
/// `cast_to_int` forwards an `int(...)`-wrapped copy to the helper.
const InBuiltin = struct {
    var_id: u32,
    name: []const u8,
    attr: []const u8,
    entry_ty: []const u8,
    impl_ty: []const u8,
    cast_to_int: bool,
};

/// Collect Input OpVariables decorated with a built-in that needs to be threaded
/// as an MSL entry-point parameter. These built-ins carry no SPIR-V Location, so
/// they are absent from the stage-in struct; without explicit threading the body
/// references them as undeclared identifiers (uncompilable MSL — silent-wrong).
/// `is_vertex` selects the vertex set (VertexIndex/InstanceIndex) vs the fragment
/// set (FrontFacing).
fn collectInputBuiltins(
    m: *const ParsedModule,
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    names: *std.AutoHashMap(u32, []const u8),
    out: *std.ArrayList(InBuiltin),
    alloc: std.mem.Allocator,
    is_vertex: bool,
) void {
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .Input) continue;
        const vid = inst.words[2];
        const bi = builtinOf(decs, vid) orelse continue;
        const ib: ?InBuiltin = if (is_vertex) switch (bi) {
            @intFromEnum(spirv.BuiltIn.vertex_index) => .{ .var_id = vid, .name = "", .attr = "vertex_id", .entry_ty = "uint", .impl_ty = "int", .cast_to_int = true },
            @intFromEnum(spirv.BuiltIn.instance_index) => .{ .var_id = vid, .name = "", .attr = "instance_id", .entry_ty = "uint", .impl_ty = "int", .cast_to_int = true },
            // gl_BaseVertex / gl_BaseInstance -> Metal [[base_vertex]] / [[base_instance]]
            // (uint at the boundary, cast to the signed int the body expects). #170
            @intFromEnum(spirv.BuiltIn.base_vertex) => .{ .var_id = vid, .name = "", .attr = "base_vertex", .entry_ty = "uint", .impl_ty = "int", .cast_to_int = true },
            @intFromEnum(spirv.BuiltIn.base_instance) => .{ .var_id = vid, .name = "", .attr = "base_instance", .entry_ty = "uint", .impl_ty = "int", .cast_to_int = true },
            else => null,
        } else switch (bi) {
            @intFromEnum(spirv.BuiltIn.front_facing) => .{ .var_id = vid, .name = "", .attr = "front_facing", .entry_ty = "bool", .impl_ty = "bool", .cast_to_int = false },
            // gl_SampleMaskIn: Metal [[sample_mask]] is a scalar uint. The body's
            // `[0]` index is dropped in writeAccessExprPlain (#481); the value is
            // forwarded as int to match the GLSL int[] element type.
            @intFromEnum(spirv.BuiltIn.sample_mask) => .{ .var_id = vid, .name = "", .attr = "sample_mask", .entry_ty = "uint", .impl_ty = "int", .cast_to_int = true },
            else => null,
        };
        if (ib) |entry| {
            const nm = names.get(vid) orelse continue;
            out.append(alloc, .{
                .var_id = vid,
                .name = nm,
                .attr = entry.attr,
                .entry_ty = entry.entry_ty,
                .impl_ty = entry.impl_ty,
                .cast_to_int = entry.cast_to_int,
            }) catch {};
        }
    }
}

/// Collect compute-stage Input built-ins that map to MSL kernel parameter
/// attributes (gl_LocalInvocationID → `uint3 [[thread_position_in_threadgroup]]`,
/// etc.). gl_GlobalInvocationID is emitted unconditionally by the compute entry
/// path, so it is intentionally excluded here to avoid a duplicate parameter.
/// Like the other built-ins these carry no Location; without explicit threading
/// the kernel body references them as undeclared identifiers (silent-wrong).
fn collectComputeBuiltins(
    m: *const ParsedModule,
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    names: *std.AutoHashMap(u32, []const u8),
    out: *std.ArrayList(InBuiltin),
    alloc: std.mem.Allocator,
) void {
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .Input) continue;
        const vid = inst.words[2];
        const bi = builtinOf(decs, vid) orelse continue;
        const spec: ?struct { ty: []const u8, attr: []const u8 } = switch (bi) {
            @intFromEnum(spirv.BuiltIn.local_invocation_id) => .{ .ty = "uint3", .attr = "thread_position_in_threadgroup" },
            @intFromEnum(spirv.BuiltIn.workgroup_id) => .{ .ty = "uint3", .attr = "threadgroup_position_in_grid" },
            @intFromEnum(spirv.BuiltIn.num_workgroups) => .{ .ty = "uint3", .attr = "threadgroups_per_grid" },
            @intFromEnum(spirv.BuiltIn.local_invocation_index) => .{ .ty = "uint", .attr = "thread_index_in_threadgroup" },
            // #subgroup-operand: SubgroupLocalInvocationId (BuiltIn 41) -> the lane
            // index within the simdgroup. Without this the body referenced an
            // undeclared gl_SubgroupInvocationID (MSL has no such builtin).
            41 => .{ .ty = "uint", .attr = "thread_index_in_simdgroup" },
            else => null,
        };
        if (spec) |s| {
            const nm = names.get(vid) orelse continue;
            out.append(alloc, .{ .var_id = vid, .name = nm, .attr = s.attr, .entry_ty = s.ty, .impl_ty = s.ty, .cast_to_int = false }) catch {};
        }
    }
}

/// Compute natural byte size of a SPIR-V scalar/vector type.
fn typeNatSize(m: *const ParsedModule, type_id: u32) u32 {
    const inst = getDef(m, type_id) orelse return 4;
    return switch (inst.op) {
        .TypeFloat => 4,
        .TypeInt => 4,
        .TypeVector => v: {
            const count = inst.words[3];
            const elem_sz = typeNatSize(m, inst.words[2]);
            break :v count * elem_sz;
        },
        .TypeMatrix => v: {
            const cols = inst.words[3];
            const rows = getDef(m, inst.words[2]) orelse break :v 16;
            const row_count = if (rows.op == .TypeVector) rows.words[3] else 1;
            break :v cols * row_count * 4;
        },
        // #479: compute the struct's natural Metal size (was hardcoded 4, causing
        // UBO padding gaps to be miscomputed — the next member ended up at the wrong
        // offset). Sum the member sizes (4-byte alignment; Metal packed_float3 is
        // also 4-byte aligned in UBOs).
        .TypeStruct => blk: {
            var sz: u32 = 0;
            for (inst.words[2..]) |mt_id| {
                sz += typeNatSize(m, mt_id);
            }
            break :blk sz;
        },
        else => 4,
    };
}

/// Return the widened Metal element type for an array in a UBO struct,
/// given the SPIR-V ArrayStride, matching spirv-cross --msl. In std140 each
/// array element is rounded up to a 16-byte boundary, so a stride larger than
/// the element's natural size means the element type must be widened to its
/// 16-byte form (e.g. float→float4, int→int4, vec2→float4). Verified vs the
/// oracle: float[]→float4[] int[]→int4[] uint[]→uint4[] vec2[]→float4[]
/// vec3[]→float3[] vec4[]→float4[] ivec2[]→int4[] uvec3[]→uint3[]
/// mat3[]→float3x3[] mat4[]→float4x4[].
///
/// Any element whose correct widened std140→MSL form is NOT implemented returns
/// error.UnsupportedUboMemberLayout — zioshade fails LOUDLY rather than emitting a
/// silent-wrong (wrong-stride / wrong-type) array layout.
fn mslWidenedElementType(m: *const ParsedModule, elem_type_id: u32, stride: u32, matrix_stride: ?u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const elem_inst = getDef(m, elem_type_id) orelse return error.UnsupportedUboMemberLayout;
    // Matrix elements: the MSL type is driven by the member's MatrixStride
    // (the ArrayStride is cols*MatrixStride). Independent of the array stride.
    if (elem_inst.op == .TypeMatrix) return try mslMatrixMemberType(m, elem_inst, matrix_stride, alloc);
    // Struct elements: the struct carries its own per-member Offset/packing
    // decorations and is emitted as a separate `struct` decl (whose members go
    // through mslUboMemberType, so vec3s get packed_float3 etc.). Its natural MSL
    // size therefore already equals the std140/std430 ArrayStride, so spirv-cross
    // emits `Foo arr[N];` directly with no widening — match that. (typeNatSize
    // returns 4 for a struct, so without this the stride>nat path would reach the
    // scalar/vector branches and honest-error on the struct element.)
    if (elem_inst.op == .TypeStruct) return try mslPackedType(m, elem_type_id, names, alloc);
    const nat = typeNatSize(m, elem_type_id);
    if (stride <= nat) return try mslPackedType(m, elem_type_id, names, alloc);
    // stride > nat: must widen the element so the natural array stride == std140.
    if (elem_inst.op == .TypeFloat) {
        if (stride == 16) {
            // 32-bit float scalar → float4 (16 B). half (16-bit) is unhandled.
            if (!(elem_inst.words.len > 2 and elem_inst.words[2] == 16)) return "float4";
        }
        return error.UnsupportedUboMemberLayout;
    }
    if (elem_inst.op == .TypeInt) {
        if (stride == 16) {
            const signed = elem_inst.words.len > 3 and elem_inst.words[3] != 0;
            return if (signed) "int4" else "uint4";
        }
        return error.UnsupportedUboMemberLayout;
    }
    if (elem_inst.op == .TypeVector) {
        const count = elem_inst.words[3];
        const scalar = getDef(m, elem_inst.words[2]);
        // Determine the 32-bit MSL scalar prefix for the vector element.
        const prefix: ?[]const u8 = if (scalar) |s| switch (s.op) {
            .TypeFloat => if (s.words.len > 2 and s.words[2] == 16) null else @as([]const u8, "float"),
            .TypeInt => if (s.words.len > 3 and s.words[3] != 0) @as([]const u8, "int") else @as([]const u8, "uint"),
            else => null,
        } else null;
        // std140 vec2/vec3/vec4 array elements all round up to 16 B. spirv-cross
        // widens a 2-component element to a 4-component vector (vec2→float4,
        // ivec2→int4); a 3-component element stays vec3 (float3/int3 is already
        // 16-byte aligned in MSL); a 4-component element stays vec4.
        if (prefix) |p| {
            if (stride == 16) {
                if (count == 2) return std.fmt.allocPrint(alloc, "{s}4", .{p});
                if (count == 3) return std.fmt.allocPrint(alloc, "{s}3", .{p});
                if (count == 4) return std.fmt.allocPrint(alloc, "{s}4", .{p});
            }
        }
        return error.UnsupportedUboMemberLayout;
    }
    // Unknown element kind with a widening stride: do NOT guess a layout.
    return error.UnsupportedUboMemberLayout;
}

// Emit forward declarations for every struct reachable from a UBO/SSBO block.
// Unlike the generic common.commonEmitStructForwardDecls (which types members
// with plain mslType), this routes each nested struct's members through
// emitStructMembers so they get the SAME std140/std430-aware treatment as the
// top-level block: vec3 -> packed_float3 when tightly followed, matrices sized
// by their MatrixStride, and array elements widened by their ArrayStride. A
// nested struct's natural MSL layout must equal its std140/std430 size or an
// array of it (`Foo arr[N];`) silently reads at the wrong stride.
//
// NOTE: only use this for BLOCK-reachable structs, which carry the Offset/
// ArrayStride/MatrixStride decorations emitStructMembers depends on. For
// Function-storage LOCAL structs (no layout decorations) use the generic
// mslEmitOneStructForwardDecl below — they want natural MSL types, not packed.
fn mslEmitStructForwardDecls(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), root_type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void), member_offsets: *const std.AutoHashMap(MemberKey, u32), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) !void {
    const inst = getDef(m, root_type_id) orelse return;
    if (inst.op != .TypeStruct) return;
    if (inst.words.len <= 2) return;
    for (inst.words[2..]) |mt_id| {
        try mslEmitUboNestedStructDecl(m, names, mt_id, w, alloc, emitted, emitted_names, member_offsets, decs);
    }
}

fn mslEmitUboNestedStructDecl(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void), member_offsets: *const std.AutoHashMap(MemberKey, u32), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) !void {
    const inst = getDef(m, type_id) orelse return;
    switch (inst.op) {
        .TypeStruct => {
            // Emit dependency structs (members + array/vector/matrix element
            // structs) before this one so C-style decls are ordered correctly.
            if (inst.words.len > 2) {
                for (inst.words[2..]) |mt_id| {
                    try mslEmitUboNestedStructDecl(m, names, mt_id, w, alloc, emitted, emitted_names, member_offsets, decs);
                }
            }
            if (emitted.get(type_id) != null) return;
            const sname = names.get(type_id) orelse "Struct";
            if (emitted_names.get(sname) != null) return;
            try emitted.put(type_id, {});
            try emitted_names.put(sname, {});
            try w.print("struct {s}\n{{\n", .{sname});
            try emitStructMembers(m, names, type_id, sname, w, alloc, member_offsets, decs);
            try w.writeAll("};\n");
        },
        .TypeArray, .TypeRuntimeArray => if (inst.words.len > 2) try mslEmitUboNestedStructDecl(m, names, inst.words[2], w, alloc, emitted, emitted_names, member_offsets, decs),
        .TypeMatrix, .TypeVector => if (inst.words.len > 2) try mslEmitUboNestedStructDecl(m, names, inst.words[2], w, alloc, emitted, emitted_names, member_offsets, decs),
        else => {},
    }
}

// Generic struct forward-decl for Function-storage LOCAL structs (no std140/
// std430 layout decorations) — members keep their natural MSL types via mslType.
fn mslEmitOneStructForwardDecl(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void)) !void {
    return common.commonEmitOneStructForwardDecl(m, names, type_id, w, alloc, emitted, emitted_names, mslType, getMemberName);
}

/// MSL type for a non-array UBO/SSBO struct member, matching spirv-cross's
/// natural-layout strategy (no `[[offset]]`).
///
/// For 3-component vectors std140 diverges from MSL's `packed_*3` (12 bytes):
/// spirv-cross emits `packed_float3` (12 B) ONLY when the next member is packed
/// tightly into the trailing 4 bytes (its std140 offset == this offset + 12);
/// otherwise it emits the 16-byte-aligned form (`float3`) so the following
/// member (or struct tail) lands at its std140 16-byte boundary without any
/// explicit padding. Replicating that choice keeps the natural MSL layout equal
/// to std140 — so we never need (the non-standard, spirv-cross-omitted)
/// `[[offset]]` on a `constant U&` buffer struct member.
fn mslUboMemberType(
    m: *const ParsedModule,
    mt_id: u32,
    this_off: ?u32,
    next_off: ?u32,
    matrix_stride: ?u32,
    names: *std.AutoHashMap(u32, []const u8),
    alloc: std.mem.Allocator,
) ![]const u8 {
    const inst = getDef(m, mt_id) orelse return try mslPackedType(m, mt_id, names, alloc);
    if (inst.op == .TypeMatrix) {
        // Resolve the matrix MSL type from its real MatrixStride (std140 vs
        // std430 differ). mslPackedType would honest-error here (no stride).
        return try mslMatrixMemberType(m, inst, matrix_stride, alloc);
    }
    if (inst.op == .TypeVector and inst.words[3] == 3) {
        // 3-vec is tightly packed (12 B) only when the next member sits exactly
        // 12 bytes after this one. A trailing 3-vec (no next member) or one
        // followed by a 16-aligned member uses the 16-byte form (mslType →
        // float3/half3/int3/uint3).
        const tight = if (this_off) |to| (if (next_off) |no| no == to + 12 else false) else false;
        return if (tight)
            try mslPackedType(m, mt_id, names, alloc)
        else
            try mslType(m, mt_id, names, alloc);
    }
    return try mslPackedType(m, mt_id, names, alloc);
}

fn emitStructMembers(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_id: u32, cb_name: []const u8, w: anytype, alloc: std.mem.Allocator, member_offsets: *const std.AutoHashMap(MemberKey, u32), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) !void {
    _ = cb_name;
    const inst = getDef(m, struct_id) orelse return;
    if (inst.op != .TypeStruct) return;
    const member_count = inst.words.len - 2;
    for (inst.words[2..], 0..) |mt_id, mi| {
        const key = MemberKey{ .struct_id = struct_id, .member_index = @intCast(mi) };
        const this_off = member_offsets.get(key);
        // #479: emit explicit padding if there's a gap from the previous member's
        // natural end to this member's std140 offset (e.g. a small struct rounds
        // to 16 in std140 but its Metal size is < 16). Mirrors spirv-cross's
        // `char _mN_pad[...]`.
        if (this_off) |off| {
            if (mi > 0) {
                const prev_key = MemberKey{ .struct_id = struct_id, .member_index = @intCast(mi - 1) };
                if (member_offsets.get(prev_key)) |prev_off| {
                    const prev_mt_id = inst.words[1 + mi];
                    const prev_end = prev_off + typeNatSize(m, prev_mt_id);
                    if (off > prev_end) {
                        try w.print("    char _m{d}_pad[{d}];\n", .{ mi, off - prev_end });
                    }
                }
            }
        }
        // Next member's std140 offset (used for the vec3 packed/16-byte choice).
        const next_off = if (mi + 1 < member_count)
            member_offsets.get(MemberKey{ .struct_id = struct_id, .member_index = @intCast(mi + 1) })
        else
            null;
        // Source member name (OpMemberName); falls back to `_m{i}` exactly as
        // the body's access-chain emitter does — keeping decl<->body consistent.
        var mname_buf: [32]u8 = undefined;
        const mname = getMemberName(m, struct_id, @intCast(mi), &mname_buf);
        // MatrixStride is a per-member decoration (present for any matrix or
        // matrix-array member). It drives the MSL row count for matrices and
        // differs between std140 (16) and std430 (8/16) — never assume one.
        const mat_stride = memberMatrixStride(m, struct_id, @intCast(mi));
        // Non-square / unsupported row_major matrix layouts are rejected up front
        // by checkUnsupportedRowMajor (covers nested structs too), so the matrix
        // members reaching here are either column_major or square row_major.
        const mti = getDef(m, mt_id);
        if (mti) |mi2| {
            if (mi2.op == .TypeArray and mi2.words.len > 3) {
                const elem_type_id = mi2.words[2];
                const li = getDef(m, mi2.words[3]);
                const lv: u32 = if (li) |l| l.words[3] else 1;
                // Check for ArrayStride decoration on the array type. A 16-byte
                // stride widens the element to float4 so the natural array stride
                // matches std140 (matching spirv-cross) — no [[offset]] needed.
                const stride = getDecVal(decs, mt_id, .array_stride);
                const et = if (stride) |s|
                    try mslWidenedElementType(m, elem_type_id, s, mat_stride, names, alloc)
                else
                    try mslPackedType(m, elem_type_id, names, alloc);
                try w.print("    {s} {s}[{d}];\n", .{ et, mname, lv });
                continue;
            }
        }
        // Runtime (flexible) array member `T m[]` — SPIR-V OpTypeRuntimeArray.
        // Emit it as `T m[1]` (the spirv-cross convention): a scalar `T m;`
        // would be invalid the moment the body indexes `m[i]` (silent-wrong).
        if (mti) |mi2| {
            if (mi2.op == .TypeRuntimeArray and mi2.words.len > 2) {
                const elem_type_id = mi2.words[2];
                const stride = getDecVal(decs, mt_id, .array_stride);
                // Resolve the element type. Scalars/vectors may need std140/std430
                // widening; structs and anything the packed/widened resolver rejects
                // (e.g. `Foo data[]` — a runtime array OF a struct) fall back to the
                // plain element-type name (`mslType`), which spirv-cross also uses
                // (`Foo data[1];`). The fallback prevents this branch from turning a
                // previously-emitted shader into an UnsupportedUboMemberLayout error.
                const et: []const u8 = blk: {
                    const widened = if (stride) |s|
                        mslWidenedElementType(m, elem_type_id, s, mat_stride, names, alloc)
                    else
                        mslPackedType(m, elem_type_id, names, alloc);
                    if (widened) |w_ok| break :blk w_ok else |_| {}
                    break :blk try mslType(m, elem_type_id, names, alloc);
                };
                try w.print("    {s} {s}[1];\n", .{ et, mname });
                continue;
            }
        }
        const mt = try mslUboMemberType(m, mt_id, this_off, next_off, mat_stride, names, alloc);
        try w.print("    {s} {s};\n", .{ mt, mname });
    }
}

// ---- Std450 → MSL function name mapping ----
fn std450ToMsl(val: u32) ?[]const u8 {
    return switch (val) {
        1 => "round",
        2 => "rint",
        3 => "trunc",
        4, 5 => "abs",
        6, 7 => "sign",
        8 => "floor",
        9 => "ceil",
        10 => "fract",
        // 11 (Radians) / 12 (Degrees) have NO MSL builtin — handled inline in the
        // .ExtInst arm as a multiply by pi/180 or 180/pi. Intentionally NOT mapped
        // here: a bypass would emit `radians()`/`degrees()`, which do not exist in
        // Metal and fail to compile, rather than a visible unhandled stub.
        13 => "sin",
        14 => "cos",
        15 => "tan",
        16 => "asin",
        17 => "acos",
        18 => "atan",
        25 => "atan2",
        19 => "sinh",
        20 => "cosh",
        21 => "tanh",
        22 => "asinh",
        23 => "acosh",
        24 => "atanh",
        26 => "powr",
        27 => "exp",
        28 => "log",
        29 => "exp2",
        30 => "log2",
        31 => "sqrt",
        32 => "rsqrt",
        33 => "determinant",
        // 34 (MatrixInverse) has no MSL builtin — handled inline in the .ExtInst arm via
        // the generated spvInverseNxN helper. Intentionally NOT mapped here: if a bypass
        // ever reached emitStd450 it would emit a visible `// unhandled std450 #34` stub
        // (non-compiling), not a plausible-looking but non-existent `inverse()` call.
        // GLSL.std.450 spec order: FMin(37) UMin(38) SMin(39) FMax(40) UMax(41) SMax(42).
        37 => "min",
        38 => "min",
        39 => "min",
        40 => "max",
        41 => "max",
        42 => "max",
        43 => "clamp",
        44 => "clamp",
        // 45 = SClamp (signed-integer clamp): plain `clamp`. NOT `fast::clamp` —
        // metal::fast::clamp is float-only fast-math; on ints it round-trips through
        // float (precision loss past 2^24) or won't compile. (FClamp(43) keeps `clamp`,
        // which is correct and NaN-safe; spirv-cross uses fast::clamp there for speed.)
        45 => "clamp",
        46 => "mix",
        48 => "step",
        49 => "smoothstep",
        50 => "fma",
        52 => "frexp",
        53 => "ldexp",
        66 => "length",
        67 => "distance",
        68 => "cross",
        69 => "normalize",
        70 => "faceforward",
        71 => "reflect",
        72 => "refract",
        // 73/74/75 (FindILsb/FindSMsb/FindUMsb) are handled inline in the .ExtInst arm
        // (findMSB/findLSB are NOT raw ctz/clz). Intentionally NOT mapped here so a bypass
        // would emit a visible `// unhandled` stub (non-compiling) rather than silently
        // emitting the wrong count.
        79 => "min",
        80 => "max",
        81 => "clamp",
        35 => "modf",
        36 => "modf",
        51 => "frexp",
        54 => "pack_float_to_snorm4x8",
        55 => "pack_float_to_unorm4x8",
        56 => "pack_float_to_snorm2x16",
        57 => "pack_float_to_unorm2x16",
        // 58 (PackHalf2x16) / 62 (UnpackHalf2x16) have no MSL builtin — handled inline in
        // the .ExtInst arm via half+as_type. Intentionally NOT mapped here: a bypass would
        // emit a visible `// unhandled` stub (non-compiling) rather than the non-existent
        // pack_float_to_half2x16.
        60 => "unpack_snorm2x16_to_float",
        61 => "unpack_unorm2x16_to_float",
        63 => "unpack_snorm4x8_to_float",
        64 => "unpack_unorm4x8_to_float",
        // 76/77/78 (InterpolateAtCentroid/Sample/Offset) are intentionally NOT mapped
        // here: Metal has no such free functions. They are handled in the .ExtInst
        // dispatch arm as METHOD calls on an `interpolant<>` field. Leaving them out so
        // that, if a refactor ever bypasses that arm, emitStd450 produces a VISIBLE
        // `// unhandled std450 #76` stub rather than silently re-emitting the broken
        // free-function form this fix removed.
        else => null,
    };
}

// ---- Function emission (MSL dialect) ----

/// Render a scalar OpConstant / OpSpecConstant / bool-constant id as an MSL literal
/// (float via {d}; signed int sign-corrected via @bitCast). Falls back to the
/// constant's already-declared module name, then "0". Used to initialize the
/// per-invocation local copy of a mutable module-scope (Private) global.
fn mslConstLiteral(m: *const ParsedModule, const_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const c = getDef(m, const_id) orelse return "0";
    if (c.op == .ConstantTrue) return "true";
    if (c.op == .ConstantFalse) return "false";
    if (c.op == .Constant and c.words.len >= 4) {
        const ty = getDef(m, c.words[1]) orelse return "0";
        const lit = c.words[3];
        if (ty.op == .TypeFloat) {
            const fv: f32 = @bitCast(lit);
            return std.fmt.allocPrint(alloc, "{d}", .{fv});
        }
        if (ty.op == .TypeInt and ty.words.len >= 4 and ty.words[3] == 1) {
            const iv: i32 = @bitCast(lit);
            return std.fmt.allocPrint(alloc, "{d}", .{iv});
        }
        return std.fmt.allocPrint(alloc, "{d}", .{lit});
    }
    return names.get(const_id) orelse "0";
}

fn emitFunction(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    func_id: u32,
    w: anytype,
    alloc: std.mem.Allocator,
    is_entry: bool,
    opi: *const std.AutoHashMap(u32, std.ArrayList(usize)),
    cbuffers: *const std.ArrayList(CbufferDecl),
    textures: *const std.ArrayList(TextureDecl),
    storage_buffers: *const std.ArrayList(CbufferDecl),
    stage_inputs: *const std.ArrayList(StageInputDecl),
    stage_outputs: *const std.ArrayList(StageOutputDecl),
    is_compute: bool,
    binding_shift: i32,
    argument_buffers: bool,
    resource_bindings: []const MslResourceBinding,
    pull_model: *const std.AutoHashMap(u32, void),
    atomic_images: *const std.AutoHashMap(u32, void),
    arraylen_buf_index: *const std.AutoHashMap(u32, u32),
) !void {
    // opi (detectOutParams) is retained for API symmetry with the other backends
    // but no longer consulted: any Function-storage pointer param is emitted as
    // `thread T&` directly (a pointer param is always out/inout), which is
    // call-site-independent and so covers the local-argument case opi missed.
    _ = opi;
    // pull_model is retained for call-site symmetry but no longer consulted here:
    // the stage-input rename (its only former use) moved to the caller before any
    // function is emitted, so helper functions share it too (#476).
    _ = pull_model;
    const fi = getDef(m, func_id) orelse return;
    if (fi.op != .Function or fi.words.len < 5) return;
    const fti = getDef(m, fi.words[4]) orelse return;
    const rtid = fti.words[2];
    const rt = mslValueType(m, rtid, names, alloc) catch try mslType(m, rtid, names, alloc);
    const is_frag = is_entry and m.execution_model == .Fragment;
    const is_vertex = is_entry and m.execution_model == .Vertex;
    // Fragment shader interlock (SPV_EXT_fragment_shader_interlock): when present, the
    // storage resources the fragment writes get `[[raster_order_group(0)]]` in the entry
    // wrapper signature (Metal's interlock mechanism). Dead for every non-interlock
    // fragment, so existing shaders are byte-identical.
    const has_frag_interlock = is_frag and fragmentHasInterlock(m, func_id);

    const func_idx = if (func_id < m.id_defs.len) m.id_defs[func_id] orelse return else return;
    const func_name = if (is_entry) "main0" else (names.get(func_id) orelse "func");

    var param_ids = std.ArrayList(u32).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer param_ids.deinit(alloc);
    {
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionParameter) {
                try param_ids.append(alloc, inst.words[2]);
            } else if (inst.op != .Label) {
                break;
            }
        }
    }

    // #414: out/inout params are recognized by their SPIR-V type ONLY (a
    // pointer FunctionParameter, the frontend's GLSL out/inout lowering). The
    // former `Variable + Store(param)` prologue heuristic misread GLSL's
    // by-value copy of an `in` param into a mutable local (`float d = p;`) as
    // an out param: `thread T&` signature (call sites then pass rvalues into a
    // reference, which Metal rejects), the local aliased to the param name (a
    // redefinition), and a self-assign of an undefined value. A by-value param
    // can never write back to the caller, so that promotion (and its call-site
    // "first matching Variable" alias twin) was silent-wrong by construction;
    // both are gone.

    // For MSL entry: emit wrapper that calls helper
    if (is_entry and is_frag) {
        // Emit the helper function (mainImage etc.)
        try w.writeAll("static inline __attribute__((always_inline))\n");

        // Determine return type and params
        var output_var_id: ?u32 = null;
        var frag_coord_var_id: ?u32 = null;
        for (m.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Output) output_var_id = inst.words[2];
                if (sc == .Input) {
                    // Check if this is FragCoord built-in
                    const vid = inst.words[2];
                    if (decs.get(vid)) |dlist| {
                        for (dlist.items) |de| {
                            if (de.decoration == .built_in and de.extra.len > 0 and de.extra[0] == @intFromEnum(spirv.BuiltIn.frag_coord)) {
                                frag_coord_var_id = vid;
                            }
                        }
                    }
                }
            }
        }

        // Rename the FragCoord input variable so the body uses _fragCoord parameter
        var frag_coord_full = false;
        if (frag_coord_var_id) |fcvid| {
            const pa = alloc.dupe(u8, "_fragCoord") catch unreachable;
            if (names.fetchPut(fcvid, pa) catch null) |old| alloc.free(old.value);
            frag_coord_full = fragCoordNeedsFullVec(m, fcvid);
        }
        // gl_FragCoord.z/.w readers get the full float4; the common .xy-only case
        // stays float2 (keeps the shadertoy/wintty signature byte-identical).
        const fc_ty: []const u8 = if (frag_coord_full) "float4" else "float2";

        // Location stage inputs are renamed to `in.<origname>` in the caller
        // (crossCompileToMsl) BEFORE any function is emitted, so both this entry
        // body AND non-entry helper functions resolve varyings through the stage-in
        // struct (#476). The Load handler copies the pointer's name to the load
        // result and buildAccessExpr resolves access-chains/swizzles via
        // names.get(base), so every downstream use inherits `in.<name>` (e.g.
        // in.uv, in.color.x). The struct fields captured the ORIGINAL source names,
        // so the rename is body-only. FragCoord is still renamed above.

        // Fragment input built-ins (gl_FrontFacing → bool [[front_facing]]). Like
        // the vertex case, these carry no Location and would otherwise leak as
        // undeclared identifiers. Threaded as an entry-point param + helper arg.
        var frag_in_builtins = std.ArrayList(InBuiltin).initCapacity(alloc, 2) catch return error.OutOfMemory;
        defer frag_in_builtins.deinit(alloc);
        collectInputBuiltins(m, decs, names, &frag_in_builtins, alloc, false);

        // Helper function signature: void mainImage(thread float4& out, float2 fragCoord, ...)
        try w.writeAll("void ");
        try w.writeAll(func_name);
        try w.writeAll("_impl(");

        var first_param = true;

        // Add output param(s). The single-color common case threads one `thread T&`
        // (byte-identical legacy path); the multi-output case (#472) threads every
        // fragment output (colors by location, then FragDepth/SampleMask/stencil).
        const frag_multi_outputs = g_frag_outputs;
        if (frag_multi_outputs) |list| {
            for (list, 0..) |fo, i| {
                if (i > 0) try w.writeAll(", ");
                const tn = fragOutputMslType(m, fo, names, alloc);
                try w.print("thread {s}& {s}", .{ tn, fo.name });
            }
            first_param = false;
        } else if (output_var_id) |ovid| {
            const on = names.get(ovid) orelse "_fragColor";
            const oty = fragmentOutputMslType(m, names, decs, alloc);
            try w.print("thread {s}& {s}", .{ oty, on });
            first_param = false;
        }

        // Add frag coord param
        if (output_var_id != null or frag_multi_outputs != null) {
            try w.print(", {s} _fragCoord", .{fc_ty});
        } else {
            try w.print("{s} _fragCoord", .{fc_ty});
            first_param = false;
        }

        // Add cbuffer params
        for (cbuffers.items) |cb| {
            if (!first_param) try w.writeAll(", ");
            try w.print("constant {s}& {s}_1", .{ cb.name, cb.name });
            first_param = false;
        }
        // Add storage-buffer (SSBO) params -- device reference (fragment SSBOs, #492).
        for (storage_buffers.items) |sb| {
            if (!first_param) try w.writeAll(", ");
            try w.print("device {s}& {s}", .{ sb.name, sb.name });
            first_param = false;
        }

        // Add texture + sampler params (storage images take no sampler, #284 follow-up).
        // Atomic-accessed storage images are skipped here and bound (texture + backing
        // buffer) in the block below — mirrors the compute path.
        for (textures.items) |tex| {
            if (atomic_images.contains(tex.var_id)) continue;
            if (!first_param) try w.writeAll(", ");
            try w.print("{s} {s}", .{ tex.msl_type, tex.name });
            if (!tex.is_storage) try w.print(", sampler {s}Smplr", .{tex.name});
            first_param = false;
        }

        // Storage-image atomics in fragment (#267, mirror of the compute path): bind each
        // atomic-accessed image as a texture AND a separate `device atomic_T*` backing
        // buffer (the spvImage2DAtomicCoord scheme). Threaded into the entry _impl so the
        // body's `<img>_atomic` references resolve. Unreachable for non-atomic fragments.
        if (atomic_images.count() > 0) {
            for (textures.items) |tex| {
                if (!atomic_images.contains(tex.var_id)) continue;
                const scalar = mslAtomicImageScalar(m, tex.var_id) orelse "uint";
                if (!first_param) try w.writeAll(", ");
                try w.print("{s} {s}, device {s}* {s}_atomic", .{ tex.msl_type, tex.name, mslAtomicTypeName(scalar), tex.name });
                first_param = false;
            }
        }

        // Add stage-in struct param (by value) so the body's `in.<name>`
        // references resolve. Threaded into the entry wrapper's call below.
        if (stage_inputs.items.len > 0) {
            if (!first_param) try w.writeAll(", ");
            try w.writeAll("main0_in in");
            first_param = false;
        }

        // Fragment input built-ins by value (impl_ty matches the SPIR-V type).
        for (frag_in_builtins.items) |ib| {
            if (!first_param) try w.writeAll(", ");
            try w.print("{s} {s}", .{ ib.impl_ty, ib.name });
            first_param = false;
        }

        try w.writeAll(")\n{\n");
        // Mutable module-scope (Private) globals with a scalar initializer: Metal
        // forbids file-scope mutable vars (constant address space only), but these
        // are per-invocation and zioshade inlines every call into this one impl
        // body, so declare each as a LOCAL here, initialized to its SPIR-V default.
        // The body's bare references then resolve to it. Only MUTATED scalars:
        // read-only const globals are already module-promoted/aliased (re-declaring
        // would be a redefinition), and arrays are #173-honest-errored.
        // Same set the helper signatures thread (g_priv_globals), from the SAME
        // predicate: a global declared here but absent from the signature list, or the
        // reverse, means a helper takes a parameter its caller cannot supply.
        var decl_privs = std.ArrayList(PrivGlobal).initCapacity(alloc, 0) catch return error.OutOfMemory;
        collectThreadedPrivGlobals(m, names, &decl_privs, alloc);
        for (decl_privs.items) |pg| {
            if (pg.init_id) |iid| {
                // Initializer operand present (spirv-cross-emitted SPIR-V): init here.
                const glit = mslConstLiteral(m, iid, names, alloc) catch continue;
                try w.print("    {s} {s} = {s};\n", .{ pg.ty, pg.name, glit });
            } else {
                // No initializer operand (zioshade/glslang emit OpStore-after-decl): the
                // body's store assigns before any read; declare bare (matches SPIR-V
                // Private semantics -- undefined until stored).
                try w.print("    {s} {s};\n", .{ pg.ty, pg.name });
            }
        }
        try emitBody(m, names, decs, func_idx, w, alloc, is_frag, output_var_id, cbuffers, textures, storage_buffers, arraylen_buf_index);
        try w.writeAll("}\n\n");

        // Now emit the entry wrapper. No Output variables at all => `fragment void`
        // (must match the main0_out emission decision upstream: no struct emitted).
        if (output_var_id != null) {
            try w.writeAll("fragment main0_out ");
        } else {
            try w.writeAll("fragment void ");
        }
        try w.writeAll(func_name);
        try w.writeAll("(");

        first_param = true;
        // Stage-in struct param first (matches spirv-cross --msl, which emits
        // `main0_in in [[stage_in]]` as the leading parameter).
        if (stage_inputs.items.len > 0) {
            try w.writeAll("main0_in in [[stage_in]]");
            first_param = false;
        }
        // M6 v2: argbuf mode → emit one [[buffer(N)]] set param per used
        // descriptor set. `binding_shift` is applied to the outer
        // [[buffer(N)]] (the slot of the set struct itself), NOT to the
        // inner [[id(K)]] fields of the struct.
        // #497: track buffer-binding collisions (resource aliasing at the same set+binding).
        // For colliding resources, only the FIRST gets [[buffer(N)]]; the rest are aliased
        // from it in the entry body (spirv-cross's pattern). types.flatten (3 UBOs @ binding=0).
        var aliased_cbs = std.ArrayList(struct { name: []const u8, from: []const u8 }).initCapacity(alloc, 0) catch return error.OutOfMemory;
        defer aliased_cbs.deinit(alloc);
        var used_cb_slots = std.AutoHashMap(u32, []const u8).init(alloc);
        defer used_cb_slots.deinit();
        const has_argbuf = argument_buffers and (cbuffers.items.len > 0 or textures.items.len > 0);
        var argbuf_sets = std.ArrayList(u32).initCapacity(alloc, 4) catch return error.OutOfMemory;
        defer argbuf_sets.deinit(alloc);
        if (has_argbuf) {
            for (cbuffers.items) |cb| try addUniqueSet(&argbuf_sets, cb.descriptor_set, alloc);
            for (textures.items) |tex| try addUniqueSet(&argbuf_sets, tex.descriptor_set, alloc);
            std.mem.sort(u32, argbuf_sets.items, {}, std.sort.asc(u32));
            for (argbuf_sets.items) |set_idx| {
                if (!first_param) try w.writeAll(", ");
                const set_b = common.applyBindingShift(set_idx, binding_shift);
                try w.print("constant spvDescriptorSetBuffer{d}& set{d} [[buffer({d})]]", .{ set_idx, set_idx, set_b });
                first_param = false;
            }
        } else {
            for (cbuffers.items) |cb| {
                const cb_b = resolveMslSlot(resource_bindings, binding_shift, cb.descriptor_set, cb.binding);
                if (used_cb_slots.get(cb_b)) |first_param_name| {
                    aliased_cbs.append(alloc, .{ .name = cb.name, .from = first_param_name }) catch {};
                } else {
                    if (!first_param) try w.writeAll(", ");
                    try w.print("constant {s}& {s}_1 [[buffer({d})]]", .{ cb.name, cb.name, cb_b });
                    first_param = false;
                    const pn = std.fmt.allocPrint(alloc, "{s}_1", .{cb.name}) catch continue;
                    used_cb_slots.put(cb_b, pn) catch {};
                }
            }
            for (storage_buffers.items) |sb| {
                if (!first_param) try w.writeAll(", ");
                const sb_b = resolveMslSlot(resource_bindings, binding_shift, sb.descriptor_set, sb.binding);
                try w.print("device {s}& {s} [[buffer({d}){s}]]", .{ sb.name, sb.name, sb_b, if (has_frag_interlock) ", raster_order_group(0)" else "" });
                first_param = false;
            }
            for (textures.items) |tex| {
                if (atomic_images.contains(tex.var_id)) continue; // bound with backing buffer below
                if (!first_param) try w.writeAll(", ");
                const tex_b = resolveMslSlot(resource_bindings, binding_shift, tex.descriptor_set, tex.binding);
                // A bare sampler (msl_type=="sampler") binds to [[sampler(N)]], not [[texture(N)]].
                if (std.mem.eql(u8, tex.msl_type, "sampler")) {
                    try w.print("sampler {s} [[sampler({d})]]", .{ tex.name, tex_b });
                } else {
                    // Writable (storage) textures get raster_order_group(0) under fragment
                    // interlock — Metal's interlock mechanism (spirv-cross parity).
                    const rog = if (tex.is_storage and has_frag_interlock) ", raster_order_group(0)" else "";
                    try w.print("{s} {s} [[texture({d}){s}]]", .{ tex.msl_type, tex.name, tex_b, rog });
                    if (!tex.is_storage) try w.print(", sampler {s}Smplr [[sampler({d})]]", .{ tex.name, tex_b });
                }
                first_param = false;
            }
            // Storage-image atomics in fragment (#267): bind each atomic-accessed image as a
            // texture AND a separate `device atomic_T*` backing buffer at the next free
            // [[buffer]] slot (the spvImage2DAtomicCoord scheme). Under interlock both carry
            // raster_order_group(0). Unreachable for non-atomic fragments (gate in spirvToMSL).
            if (atomic_images.count() > 0) {
                var max_buf_slot: u32 = 0;
                var have_buf = false;
                for (storage_buffers.items) |sb| {
                    const s = resolveMslSlot(resource_bindings, binding_shift, sb.descriptor_set, sb.binding);
                    if (!have_buf or s > max_buf_slot) {
                        max_buf_slot = s;
                        have_buf = true;
                    }
                }
                for (cbuffers.items) |cb| {
                    const s = resolveMslSlot(resource_bindings, binding_shift, cb.descriptor_set, cb.binding);
                    if (!have_buf or s > max_buf_slot) {
                        max_buf_slot = s;
                        have_buf = true;
                    }
                }
                var next_atomic_buf: u32 = if (have_buf) max_buf_slot + 1 else 0;
                const arog = if (has_frag_interlock) ", raster_order_group(0)" else "";
                for (textures.items) |tex| {
                    if (!atomic_images.contains(tex.var_id)) continue;
                    const scalar = mslAtomicImageScalar(m, tex.var_id) orelse "uint";
                    const tex_b = resolveMslSlot(resource_bindings, binding_shift, tex.descriptor_set, tex.binding);
                    if (!first_param) try w.writeAll(", ");
                    try w.print("{s} {s} [[texture({d}){s}]]", .{ tex.msl_type, tex.name, tex_b, arog });
                    try w.print(", device {s}* {s}_atomic [[buffer({d}){s}]]", .{ mslAtomicTypeName(scalar), tex.name, next_atomic_buf, arog });
                    first_param = false;
                    next_atomic_buf += 1;
                }
            }
        }
        // Fragment input built-ins as MSL entry-point attributes (front_facing).
        for (frag_in_builtins.items) |ib| {
            if (!first_param) try w.writeAll(", ");
            try w.print("{s} {s} [[{s}]]", .{ ib.entry_ty, ib.name, ib.attr });
            first_param = false;
        }
        if (!first_param) try w.writeAll(", ");
        try w.writeAll("float4 gl_FragCoord [[position]])");

        if (output_var_id != null) {
            try w.writeAll("\n{\n    main0_out out = {};\n    ");
        } else {
            try w.writeAll("\n{\n    ");
        }
        // #497: Alias declarations for colliding buffer bindings (resource aliasing).
        for (aliased_cbs.items) |ac| {
            try w.print("constant {s}& {s}_1 = *(constant {s}*)&{s};\n    ", .{ ac.name, ac.name, ac.name, ac.from });
        }
        // Pass the full float4 when the body reads .z/.w, else just .xy (float2).
        // The output arguments are gated exactly like the impl signature's output
        // params: a fragment with NO Output var (e.g. it only reads inputs / has side
        // effects) omits both, so caller and callee agree on arity (#479). The multi-
        // output path (#472) passes `out.<name>` for every field; the single-color path
        // passes the legacy `out._fragColor`.
        if (g_frag_outputs) |list| {
            try w.writeAll(func_name);
            try w.writeAll("_impl(");
            for (list, 0..) |fo, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("out.{s}", .{fo.name});
            }
            try w.print(", gl_FragCoord{s}", .{if (frag_coord_full) "" else ".xy"});
        } else if (output_var_id != null) {
            try w.print("{s}_impl(out._fragColor, gl_FragCoord{s}", .{ func_name, if (frag_coord_full) "" else ".xy" });
        } else {
            try w.print("{s}_impl(gl_FragCoord{s}", .{ func_name, if (frag_coord_full) "" else ".xy" });
        }
        if (has_argbuf) {
            for (cbuffers.items) |cb| {
                try w.print(", set{d}.{s}", .{ cb.descriptor_set, cb.name });
            }
            for (textures.items) |tex| {
                try w.print(", set{d}.{s}", .{ tex.descriptor_set, tex.name });
                if (!tex.is_storage) try w.print(", set{d}.{s}Smplr", .{ tex.descriptor_set, tex.name });
            }
        } else {
            for (cbuffers.items) |cb| {
                try w.print(", {s}_1", .{cb.name});
            }
            for (storage_buffers.items) |sb| {
                try w.print(", {s}", .{sb.name});
            }
            for (textures.items) |tex| {
                if (atomic_images.contains(tex.var_id)) continue; // passed with backing buffer below
                try w.print(", {s}", .{tex.name});
                if (!tex.is_storage) try w.print(", {s}Smplr", .{tex.name});
            }
            // Pass atomic-accessed images with their backing buffers (order matches the
            // _impl signature: texture, then device atomic_T*).
            if (atomic_images.count() > 0) {
                for (textures.items) |tex| {
                    if (!atomic_images.contains(tex.var_id)) continue;
                    try w.print(", {s}, {s}_atomic", .{ tex.name, tex.name });
                }
            }
        }
        // Pass the stage-in struct last, matching the `_impl` signature order.
        if (stage_inputs.items.len > 0) try w.writeAll(", in");
        // Forward fragment input built-ins (after the stage-in struct, matching
        // the helper signature order). front_facing is bool — no cast needed.
        for (frag_in_builtins.items) |ib| {
            if (ib.cast_to_int) try w.print(", int({s})", .{ib.name}) else try w.print(", {s}", .{ib.name});
        }
        if (output_var_id != null) {
            try w.writeAll(");\n    return out;\n}\n");
        } else {
            try w.writeAll(");\n}\n");
        }
        return;
    }

    // Compute kernel entry point
    if (is_entry and is_compute) {
        // gl_WorkGroupSize (compute builtin) has no Metal attribute equivalent — the
        // threadgroup size is set at dispatch, not in source. Without a definition the
        // body reference leaks as an undeclared identifier. Emit it as a module-level
        // const (= local_size) so body references resolve, matching spirv-cross --msl.
        // (#170)
        var has_wgs = false;
        for (m.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Input) continue;
            if (std.mem.eql(u8, names.get(inst.words[2]) orelse "", "gl_WorkGroupSize")) {
                has_wgs = true;
                break;
            }
        }
        if (has_wgs) {
            try w.print("constant uint3 gl_WorkGroupSize [[maybe_unused]] = uint3({d}u, {d}u, {d}u);\n", .{
                m.local_size[0], m.local_size[1], m.local_size[2],
            });
        }
        try w.writeAll("kernel void ");
        try w.writeAll(func_name);
        try w.writeAll("(");

        var first_param = true;

        // M6 v2: in argbuf mode, UBOs / sampled images / SSBOs are all
        // routed through per-set spvDescriptorSetBufferN structs. The
        // struct exists when there's at least one resource that belongs
        // to the entry point.
        const has_argbuf = argument_buffers and
            (cbuffers.items.len > 0 or textures.items.len > 0 or storage_buffers.items.len > 0);

        var argbuf_sets = std.ArrayList(u32).initCapacity(alloc, 4) catch return error.OutOfMemory;
        defer argbuf_sets.deinit(alloc);
        if (has_argbuf) {
            for (cbuffers.items) |cb| try addUniqueSet(&argbuf_sets, cb.descriptor_set, alloc);
            for (textures.items) |tex| try addUniqueSet(&argbuf_sets, tex.descriptor_set, alloc);
            for (storage_buffers.items) |sb| try addUniqueSet(&argbuf_sets, sb.descriptor_set, alloc);
            std.mem.sort(u32, argbuf_sets.items, {}, std.sort.asc(u32));
        }

        if (has_argbuf) {
            // M6 v2.b: SSBOs participate in the set struct; emit ONE [[buffer(N)]]
            // per used descriptor set instead of legacy per-resource params.
            // `binding_shift` is applied to the outer slot of the set itself,
            // NOT to the inner [[id(K)]] fields.
            for (argbuf_sets.items) |set_idx| {
                if (!first_param) try w.writeAll(", ");
                const set_b = common.applyBindingShift(set_idx, binding_shift);
                try w.print("constant spvDescriptorSetBuffer{d}& set{d} [[buffer({d})]]", .{ set_idx, set_idx, set_b });
                first_param = false;
            }
        } else {
            // Legacy per-resource binding: storage buffers + uniform buffers.
            // Collision resolution: two resources at the same (set, binding) would
            // share a Metal [[buffer(N)]] slot — Metal rejects that. Bump the
            // second to a free slot (spirv-cross also assigns unique slots).
            var used_buf_slots = std.AutoHashMap(u32, void).init(alloc);
            defer used_buf_slots.deinit();
            for (storage_buffers.items) |sb| {
                if (!first_param) try w.writeAll(", ");
                var sb_b = resolveMslSlot(resource_bindings, binding_shift, sb.descriptor_set, sb.binding);
                while (used_buf_slots.contains(sb_b)) sb_b += 1;
                try used_buf_slots.put(sb_b, {});
                // Reference (`device T&`), NOT pointer (`device T*`): the body's
                // access-chain emitter uses `.member` (dot), which is only valid
                // on a reference — a pointer needs `->`. This mirrors the working
                // uniform-buffer pattern (`constant T& name_1`). Emitting a
                // pointer here produced invalid MSL (`.` on a pointer) for every
                // SSBO shader — silent-wrong. See docs/specs/2026-06-02-msl-ssbo-correctness.md.
                try w.print("device {s}& {s} [[buffer({d})]]", .{ sb.name, sb.name, sb_b });
                first_param = false;
            }
            for (cbuffers.items) |cb| {
                if (!first_param) try w.writeAll(", ");
                var cb_b = resolveMslSlot(resource_bindings, binding_shift, cb.descriptor_set, cb.binding);
                while (used_buf_slots.contains(cb_b)) cb_b += 1;
                try used_buf_slots.put(cb_b, {});
                try w.print("constant {s}& {s}_1 [[buffer({d})]]", .{ cb.name, cb.name, cb_b });
                first_param = false;
            }
            // Textures/storage images (#284): compute kernels previously bound NO textures,
            // so any imageLoad/imageStore/sample referenced an undeclared identifier. Bind
            // each here; sampled images also get a `sampler`, storage images do not. Atomic
            // images are bound by the #267 block below (texture + backing buffer), so skip them.
            for (textures.items) |tex| {
                if (atomic_images.contains(tex.var_id)) continue;
                if (!first_param) try w.writeAll(", ");
                const tex_b = resolveMslSlot(resource_bindings, binding_shift, tex.descriptor_set, tex.binding);
                if (tex.is_storage) {
                    try w.print("{s} {s} [[texture({d})]]", .{ tex.msl_type, tex.name, tex_b });
                } else {
                    try w.print("{s} {s} [[texture({d})]], sampler {s}Smplr [[sampler({d})]]", .{ tex.msl_type, tex.name, tex_b, tex.name, tex_b });
                }
                first_param = false;
            }
        }

        // Storage-image atomics (#267): bind each atomic-accessed image as a texture AND
        // a separate `device atomic_T*` backing buffer (the spvImage2DAtomicCoord scheme).
        // The texture itself was previously never bound in compute kernels; the backing
        // buffer is appended at the next free [[buffer]] slot ABOVE all existing buffers so
        // no existing binding shifts. (Argbuf / non-compute / non-2D were honest-errored.)
        if (atomic_images.count() > 0) {
            // Next free [[buffer]] slot = 1 + max slot used by SSBOs/UBOs (0 if none).
            var max_buf_slot: u32 = 0;
            var have_buf = false;
            for (storage_buffers.items) |sb| {
                const s = resolveMslSlot(resource_bindings, binding_shift, sb.descriptor_set, sb.binding);
                if (!have_buf or s > max_buf_slot) {
                    max_buf_slot = s;
                    have_buf = true;
                }
            }
            for (cbuffers.items) |cb| {
                const s = resolveMslSlot(resource_bindings, binding_shift, cb.descriptor_set, cb.binding);
                if (!have_buf or s > max_buf_slot) {
                    max_buf_slot = s;
                    have_buf = true;
                }
            }
            var next_atomic_buf: u32 = if (have_buf) max_buf_slot + 1 else 0;
            for (textures.items) |tex| {
                if (!atomic_images.contains(tex.var_id)) continue;
                const scalar = mslAtomicImageScalar(m, tex.var_id) orelse "uint";
                const tex_b = resolveMslSlot(resource_bindings, binding_shift, tex.descriptor_set, tex.binding);
                if (!first_param) try w.writeAll(", ");
                try w.print("{s} {s} [[texture({d})]]", .{ tex.msl_type, tex.name, tex_b });
                try w.print(", device {s}* {s}_atomic [[buffer({d})]]", .{ mslAtomicTypeName(scalar), tex.name, next_atomic_buf });
                first_param = false;
                next_atomic_buf += 1;
            }
        }

        // Faithful runtime SSBO `.length()` (#296): bind the host-provided buffer-size
        // array (spirv-cross's `spvBufferSizeConstants`). Appended at the next free
        // [[buffer]] slot ABOVE all SSBO/UBO slots so no existing binding shifts. The map
        // is non-empty only on the compute, non-argbuf, no-atomic-image path (see the
        // build site in spirvToMSL), which is exactly where this kernel signature is used.
        if (arraylen_buf_index.count() > 0) {
            var max_buf_slot: u32 = 0;
            var have_buf = false;
            for (storage_buffers.items) |sb| {
                const s = resolveMslSlot(resource_bindings, binding_shift, sb.descriptor_set, sb.binding);
                if (!have_buf or s > max_buf_slot) {
                    max_buf_slot = s;
                    have_buf = true;
                }
            }
            for (cbuffers.items) |cb| {
                const s = resolveMslSlot(resource_bindings, binding_shift, cb.descriptor_set, cb.binding);
                if (!have_buf or s > max_buf_slot) {
                    max_buf_slot = s;
                    have_buf = true;
                }
            }
            const size_slot: u32 = if (have_buf) max_buf_slot + 1 else 0;
            if (!first_param) try w.writeAll(", ");
            try w.print("constant uint* spvBufferSizeConstants [[buffer({d})]]", .{size_slot});
            first_param = false;
        }

        // Thread position
        if (!first_param) try w.writeAll(", ");
        try w.writeAll("uint3 gl_GlobalInvocationID [[thread_position_in_grid]]");

        // Other compute built-ins (gl_LocalInvocationID/gl_WorkGroupID/
        // gl_NumWorkGroups/gl_LocalInvocationIndex) as additional kernel params
        // with their MSL attribute. Without this they leak as undeclared
        // identifiers in the body (uncompilable MSL — silent-wrong).
        var cs_builtins = std.ArrayList(InBuiltin).initCapacity(alloc, 4) catch return error.OutOfMemory;
        defer cs_builtins.deinit(alloc);
        collectComputeBuiltins(m, decs, names, &cs_builtins, alloc);
        for (cs_builtins.items) |ib| {
            try w.print(", {s} {s} [[{s}]]", .{ ib.entry_ty, ib.name, ib.attr });
        }

        try w.writeAll(")\n{\n");

        // M6 v2: kernel body still references `Name_1` / `Name` / `Name` (SSBO)
        // from the body emitter. With argbuf mode, we materialise local
        // aliases of the set-struct fields so emitBody output keeps working
        // without per-instruction rewrite.
        if (has_argbuf) {
            for (cbuffers.items) |cb| {
                try w.print("    constant {s}& {s}_1 = set{d}.{s};\n", .{ cb.name, cb.name, cb.descriptor_set, cb.name });
            }
            for (textures.items) |tex| {
                try w.print("    {s} {s} = set{d}.{s};\n", .{ tex.msl_type, tex.name, tex.descriptor_set, tex.name });
                if (!tex.is_storage) try w.print("    sampler {s}Smplr = set{d}.{s}Smplr;\n", .{ tex.name, tex.descriptor_set, tex.name });
            }
            // SSBO: the body emitter accesses members via `Name.member` (dot),
            // so bind `Name` as a reference. The argument-buffer set field is a
            // `device Buf*` pointer, so dereference it: `device Buf& Name = *set.Name;`.
            for (storage_buffers.items) |sb| {
                try w.print("    device {s}& {s} = *set{d}.{s};\n", .{ sb.name, sb.name, sb.descriptor_set, sb.name });
            }
        }

        // Emit workgroup (shared) variables. These are MODULE-scope OpVariables (per
        // SPIR-V spec), so scan the whole module — not func_idx+1…FunctionEnd (which is
        // the function body and misses them -> undeclared identifier). Metal permits
        // function-scope threadgroup, so placement here (inside the impl) is valid. (#475)
        for (m.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Workgroup) {
                    const ri = inst.words[2];
                    const tn = try mslType(m, inst.words[1], names, alloc);
                    const arr = try mslGetArraySuffix(m, inst.words[1]);
                    try w.print("    threadgroup {s} {s}{s};\n", .{ tn, names.get(ri) orelse "shared_var", arr });
                }
            }
        }
        // #170: Metal kernels cannot have mutable file-scope variables, so a
        // non-const Private global (source `int i;` assigned in the body) is
        // promoted to a function-local declaration here, matching spirv-cross
        // (`int i = 0;` inside main0). Without it the body reference is an
        // undeclared identifier. Const-initialized Private globals are already
        // materialized at module scope and skipped.
        for (m.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Private) continue;
            if (common.constInitializedPrivateVar(m, inst) != null) continue;
            const tn = mslType(m, inst.words[1], names, alloc) catch continue;
            const arr = mslGetArraySuffix(m, inst.words[1]) catch continue;
            const vn = names.get(inst.words[2]) orelse continue;
            try w.print("    {s} {s}{s} = {{}};\n", .{ tn, vn, arr });
        }

        try emitBody(m, names, decs, func_idx, w, alloc, false, null, cbuffers, textures, storage_buffers, arraylen_buf_index);
        try w.writeAll("}\n");
        return;
    }

    // Vertex entry point. Mirrors the fragment wrapper structure (impl factoring):
    // a helper `main0_impl(thread main0_out& out, main0_in in, <resources>)`
    // holds the body, and a `vertex main0_out main0(...)` wrapper materialises
    // `main0_out out = {};`, calls the helper, and `return out;`.
    //
    // Outputs are threaded as the `main0_out` struct: each Output variable
    // (user varyings + gl_Position) is renamed to `out.<name>` in `names`
    // BEFORE body emit, exactly like the input `in.<name>` rename. A body store
    // `gl_Position = X` then resolves (via writeResolvePointer/names.get) to
    // `out.gl_Position = X` — gl_Position becomes a struct FIELD, never a local.
    if (is_entry and is_vertex) {
        // Rename location inputs to `in.<name>` (body refs resolve through the
        // stage-in struct; struct fields above already captured original names).
        for (stage_inputs.items) |si| {
            const aliased = std.fmt.allocPrint(alloc, "in.{s}", .{si.name}) catch continue;
            if (names.fetchPut(si.var_id, aliased) catch null) |old| alloc.free(old.value);
        }
        // Rename outputs (user varyings AND gl_Position) to `out.<name>`.
        for (stage_outputs.items) |so| {
            if (so.from_block) continue; // routed via the block var below
            const aliased = std.fmt.allocPrint(alloc, "out.{s}", .{so.name}) catch continue;
            if (names.fetchPut(so.var_id, aliased) catch null) |old| alloc.free(old.value);
        }
        // Route ALL from_block block vars (gl_PerVertex, user io-blocks) to the
        // `out` instance so OpAccessChain <block> <member> resolves to
        // out.<member>. Previously only the FIRST from_block var was routed —
        // a shader with TWO output blocks (gl_PerVertex + VertOut) left the second
        // undeclared.
        {
            var seen_block_vars = std.AutoHashMap(u32, void).init(alloc);
            defer seen_block_vars.deinit();
            for (stage_outputs.items) |so| {
                if (!so.from_block) continue;
                if (seen_block_vars.contains(so.var_id)) continue;
                seen_block_vars.put(so.var_id, {}) catch {};
                // Clip/cull honest-error for gl_PerVertex blocks.
                if (perVertexBlockStructType(m, names, so.var_id)) |sty| {
                    const sdef = getDef(m, sty).?;
                    const nmem: usize = if (sdef.words.len > 2) sdef.words.len - 2 else 0;
                    var mi: u32 = 0;
                    while (mi < nmem) : (mi += 1) {
                        const mbi = mslMemberBuiltin(m, sty, mi) orelse continue;
                        if ((mbi == .clip_distance or mbi == .cull_distance) and perVertexMemberWritten(m, so.var_id, mi)) {
                            return error.UnsupportedBuiltin;
                        }
                    }
                }
                const routed = try alloc.dupe(u8, "out");
                if (names.fetchPut(so.var_id, routed) catch null) |old| alloc.free(old.value);
            }
        }

        // Input built-ins (gl_VertexIndex → [[vertex_id]], gl_InstanceIndex →
        // [[instance_id]]). These have no SPIR-V Location, so collectStageInputs
        // skips them; without threading they leak as bare undeclared identifiers
        // (uncompilable MSL). Mirror spirv-cross: pass each as an entry-point
        // parameter (MSL builtin type `uint`) and forward an `int(...)`-cast copy
        // to the helper (the SPIR-V variable is signed int).
        var vtx_in_builtins = std.ArrayList(InBuiltin).initCapacity(alloc, 2) catch return error.OutOfMemory;
        defer vtx_in_builtins.deinit(alloc);
        collectInputBuiltins(m, decs, names, &vtx_in_builtins, alloc, true);

        // ---- Helper: void main0_impl(thread main0_out& out, main0_in in, ...) ----
        try w.writeAll("static inline __attribute__((always_inline))\n");
        try w.print("void {s}_impl(", .{func_name});
        var first_param = true;
        // Output struct by reference (always present for a vertex stage — at
        // minimum gl_Position). Guard the empty case defensively.
        if (stage_outputs.items.len > 0) {
            try w.writeAll("thread main0_out& out");
            first_param = false;
        }
        // Stage-in struct by value (only when there are location inputs).
        if (stage_inputs.items.len > 0) {
            if (!first_param) try w.writeAll(", ");
            try w.writeAll("main0_in in");
            first_param = false;
        }
        // Uniform buffers (same threading as fragment: `Name_1`).
        for (cbuffers.items) |cb| {
            if (!first_param) try w.writeAll(", ");
            try w.print("constant {s}& {s}_1", .{ cb.name, cb.name });
            first_param = false;
        }
        // Textures + samplers (stage-agnostic; storage images take no sampler, #284 follow-up).
        for (textures.items) |tex| {
            if (!first_param) try w.writeAll(", ");
            try w.print("{s} {s}", .{ tex.msl_type, tex.name });
            if (!tex.is_storage) try w.print(", sampler {s}Smplr", .{tex.name});
            first_param = false;
        }
        // Input built-ins by value (impl_ty matches the SPIR-V variable type).
        for (vtx_in_builtins.items) |ib| {
            if (!first_param) try w.writeAll(", ");
            try w.print("{s} {s}", .{ ib.impl_ty, ib.name });
            first_param = false;
        }
        try w.writeAll(")\n{\n");
        try emitBody(m, names, decs, func_idx, w, alloc, false, null, cbuffers, textures, storage_buffers, arraylen_buf_index);
        try w.writeAll("}\n\n");

        // ---- Wrapper: vertex main0_out main0(main0_in in [[stage_in]], ...) ----
        try w.print("vertex main0_out {s}(", .{func_name});
        first_param = true;
        if (stage_inputs.items.len > 0) {
            try w.writeAll("main0_in in [[stage_in]]");
            first_param = false;
        }
        // Uniform buffers bound via [[buffer(N)]] (with binding shift), matching
        // the fragment path. (Argument-buffer mode is fragment/compute only for
        // now; vertex uses the legacy per-resource binding.)
        // Collision resolution: two resources at the same (set, binding) would
        // share a Metal [[buffer(N)]] slot — Metal rejects that. Bump the second
        // to a free slot (same fix as the compute kernel signature).
        var used_buf_slots = std.AutoHashMap(u32, void).init(alloc);
        defer used_buf_slots.deinit();
        for (cbuffers.items) |cb| {
            if (!first_param) try w.writeAll(", ");
            var cb_b = resolveMslSlot(resource_bindings, binding_shift, cb.descriptor_set, cb.binding);
            while (used_buf_slots.contains(cb_b)) cb_b += 1;
            try used_buf_slots.put(cb_b, {});
            try w.print("constant {s}& {s}_1 [[buffer({d})]]", .{ cb.name, cb.name, cb_b });
            first_param = false;
        }
        for (textures.items) |tex| {
            if (!first_param) try w.writeAll(", ");
            const tex_b = resolveMslSlot(resource_bindings, binding_shift, tex.descriptor_set, tex.binding);
            try w.print("{s} {s} [[texture({d})]]", .{ tex.msl_type, tex.name, tex_b });
            if (!tex.is_storage) try w.print(", sampler {s}Smplr [[sampler({d})]]", .{ tex.name, tex_b });
            first_param = false;
        }
        // Input built-ins as MSL entry-point attributes (uint vertex_id/instance_id).
        for (vtx_in_builtins.items) |ib| {
            if (!first_param) try w.writeAll(", ");
            try w.print("{s} {s} [[{s}]]", .{ ib.entry_ty, ib.name, ib.attr });
            first_param = false;
        }
        try w.writeAll(")\n{\n    main0_out out = {};\n    ");
        try w.print("{s}_impl(", .{func_name});
        var first_arg = true;
        if (stage_outputs.items.len > 0) {
            try w.writeAll("out");
            first_arg = false;
        }
        if (stage_inputs.items.len > 0) {
            if (!first_arg) try w.writeAll(", ");
            try w.writeAll("in");
            first_arg = false;
        }
        for (cbuffers.items) |cb| {
            if (!first_arg) try w.writeAll(", ");
            try w.print("{s}_1", .{cb.name});
            first_arg = false;
        }
        for (textures.items) |tex| {
            if (!first_arg) try w.writeAll(", ");
            try w.print("{s}", .{tex.name});
            if (!tex.is_storage) try w.print(", {s}Smplr", .{tex.name});
            first_arg = false;
        }
        // Forward each input built-in to the helper, casting uint→int where the
        // body expects the signed SPIR-V type (vertex_id/instance_id).
        for (vtx_in_builtins.items) |ib| {
            if (!first_arg) try w.writeAll(", ");
            if (ib.cast_to_int) try w.print("int({s})", .{ib.name}) else try w.print("{s}", .{ib.name});
            first_arg = false;
        }
        try w.writeAll(");\n    return out;\n}\n");
        return;
    }

    // Non-entry function — append cbuffer and texture/sampler params
    // so the function body can access Globals_1, iChannel0, etc.
    if (std.mem.eql(u8, rt, "void")) {
        try w.print("void {s}(", .{func_name});
    } else {
        try w.print("{s} {s}(", .{ rt, func_name });
    }

    var first_param = true;
    for (param_ids.items) |pid| {
        if (!first_param) try w.writeAll(", ");
        first_param = false;
        const pi = getDef(m, pid).?;
        const pn = names.get(pid) orelse "p";
        const pti = getDef(m, pi.words[1]);
        var is_ptr = false;
        var itid = pi.words[1];
        if (pti) |pt| {
            if (pt.op == .TypePointer and pt.words.len > 3) {
                itid = pt.words[3];
                is_ptr = true;
            }
        }
        // Opaque sampler/image params (by-value, not pointers) -- Metal has separate
        // sampler/texture types. mslType falls to float4 for these; type them directly.
        // combined-texture-sampler (bare sampler/image fn params).
        if (getDef(m, itid)) |it| {
            if (it.op == .TypeSampler) {
                try w.print("sampler {s}", .{pn});
                continue;
            }
            if (it.op == .TypeImage or it.op == .TypeSampledImage) {
                const img = if (it.op == .TypeSampledImage and it.words.len > 2) (getDef(m, it.words[2]) orelse it) else it;
                if (img.op == .TypeImage) {
                    const dim: u32 = if (img.words.len > 3) img.words[3] else 1;
                    const arrayed = img.words.len > 5 and img.words[5] == 1;
                    const ms = img.words.len > 6 and img.words[6] == 1;
                    const tex_ty = buildMslTextureType(alloc, imageTypeIsDepth(m, img), dim, arrayed, ms, mslSampledComponent(m, img), "");
                    try w.print("{s} {s}", .{ tex_ty, pn });
                    continue;
                }
            }
        }
        const pt2 = try mslType(m, itid, names, alloc);
        // A Function-storage pointer param is always out/inout (the frontend emits a
        // pointer only for those, never a by-value copy); Metal passes both as a
        // `thread T&` reference. This used to be gated on opi (detectOutParams), which
        // only records the shadertoy Output-arg case, so a local-argument pointer
        // param degraded to a by-value copy and its writes were lost (silent-wrong).
        if (is_ptr) {
            try w.print("thread {s}& {s}", .{ pt2, pn });
        } else {
            try w.print("{s} {s}", .{ pt2, pn });
        }
    }

    // Add cbuffer params to non-entry functions
    for (cbuffers.items) |cb| {
        if (!first_param) try w.writeAll(", ");
        first_param = false;
        try w.print("constant {s}& {s}_1", .{ cb.name, cb.name });
    }
    // Add SSBO params to non-entry functions (a helper that reads/writes a
    // storage buffer needs it in scope — mirrors the cbuffer threading).
    for (storage_buffers.items) |sb| {
        if (!first_param) try w.writeAll(", ");
        first_param = false;
        try w.print("device {s}& {s}", .{ sb.name, sb.name });
    }
    // Add texture + sampler params to non-entry functions
    // (storage images take no sampler, #284 follow-up).
    for (textures.items) |tex| {
        if (!first_param) try w.writeAll(", ");
        first_param = false;
        try w.print("{s} {s}", .{ tex.msl_type, tex.name });
        if (!tex.is_storage) try w.print(", sampler {s}Smplr", .{tex.name});
    }
    // #476: a non-entry helper that reads a location varying (aliased to `in.<name>`)
    // needs the stage-in struct in scope. Thread `main0_in in` uniformly (fragment OR
    // vertex with varyings), matching the call-site append gated on g_has_stage_in.
    if (stage_inputs.items.len > 0) {
        if (!first_param) try w.writeAll(", ");
        first_param = false;
        try w.writeAll("main0_in in");
    }
    // #489: thread the fragment output into helpers (a helper that writes it needs it).
    // #472: the multi-output path threads EVERY fragment output (one param each).
    if (g_frag_outputs) |list| {
        for (list) |fo| {
            if (!first_param) try w.writeAll(", ");
            first_param = false;
            const tn = fragOutputMslType(m, fo, names, alloc);
            try w.print("thread {s}& {s}", .{ tn, fo.name });
        }
    } else if (g_frag_out_type) |oty| {
        if (!first_param) try w.writeAll(", ");
        first_param = false;
        try w.print("thread {s}& {s}", .{ oty, g_frag_out_name orelse "_fragColor" });
    }
    // #489: thread gl_FragCoord (_fragCoord) into helpers (a helper that reads it).
    if (g_frag_coord_ty) |fty| {
        if (!first_param) try w.writeAll(", ");
        first_param = false;
        try w.print("{s} _fragCoord", .{fty});
    }
    // Mutated Private globals. The entry impl owns the storage; helpers take a
    // reference, so a store in a helper is visible to the entry and to sibling calls,
    // which is what Private storage means in SPIR-V.
    if (g_priv_globals) |list| {
        for (list) |pg| {
            if (!first_param) try w.writeAll(", ");
            first_param = false;
            try w.print("thread {s}& {s}", .{ pg.ty, pg.name });
        }
    }

    // #480: forward-prototype pass emits `<signature>;` and stops before the body.
    if (g_proto_only) {
        try w.writeAll(");\n");
        return;
    }
    try w.writeAll(")\n{\n");
    try emitBody(m, names, decs, func_idx, w, alloc, false, null, cbuffers, textures, storage_buffers, arraylen_buf_index);
    try w.writeAll("}\n");
}

/// The mutated Private globals that get promoted to entry-impl locals and threaded
/// into helpers. Metal forbids file-scope mutable variables, so a Private global has
/// to become a local somewhere; if any function other than the entry references it,
/// that local must also be passed by reference to the functions that do.
///
/// Scalars, vectors and matrices only. A struct would need its type emitted at module
/// scope (only the UBO path does that today) and an array keeps the #173 honest error.
/// Read-only globals are excluded by the mutation check: they are already module-scope
/// promoted or aliased, so declaring them again would be a redefinition.
fn collectThreadedPrivGlobals(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), out: *std.ArrayList(PrivGlobal), alloc: std.mem.Allocator) void {
    for (m.instructions) |ginst| {
        if (ginst.op != .Variable or ginst.words.len < 4) continue;
        if (@as(spirv.StorageClass, @enumFromInt(ginst.words[3])) != .Private) continue;
        if (common.constInitializedPrivateVar(m, ginst) != null) continue;
        const gptr = getDef(m, ginst.words[1]) orelse continue;
        if (gptr.op != .TypePointer or gptr.words.len < 4) continue;
        const gpt = gptr.words[3];
        const gpti = getDef(m, gpt) orelse continue;
        switch (gpti.op) {
            .TypeFloat, .TypeInt, .TypeBool, .TypeVector, .TypeMatrix => {},
            // Structs are admitted now that the module-scope struct scan covers Private
            // storage. Arrays (#173): admitted as spvUnsafeArray<T, N> locals when they
            // have NO initializer operand (the mutated glslang/zioshade shape) — the
            // wrapper is reference-passable, assignable and indexable, so the same
            // threading machinery works. Initialized or unmutated arrays keep the
            // honest error (see the prepass refusal).
            .TypeStruct => {},
            .TypeArray => {
                if (ginst.words.len >= 5) continue; // initializer: not this path
            },
            else => continue,
        }
        const gvar = ginst.words[2];
        var mutated = false;
        for (m.instructions) |u| {
            if (u.op == .Store and u.words.len >= 3 and pointerRootsAt(m, u.words[1], gvar)) {
                mutated = true;
                break;
            }
        }
        if (!mutated) continue;
        const gname = names.get(gvar) orelse continue;
        const gtn = if (gpti.op == .TypeArray)
            (mslValueType(m, gpt, names, alloc) catch continue)
        else
            (mslType(m, gpt, names, alloc) catch continue);
        out.append(alloc, .{
            .var_id = gvar,
            .name = gname,
            .ty = gtn,
            .init_id = if (ginst.words.len >= 5) ginst.words[4] else null,
        }) catch {};
    }
}

// ---- Body/Block/Instruction emission (same structure as GLSL backend) ----

fn emitBody(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    func_idx: usize,
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    output_var_id: ?u32,
    cbuffers: *const std.ArrayList(CbufferDecl),
    textures: *const std.ArrayList(TextureDecl),
    storage_buffers: *const std.ArrayList(CbufferDecl),
    arraylen_buf_index: *const std.AutoHashMap(u32, u32),
) !void {
    var label_map = std.AutoHashMap(u32, usize).init(alloc);
    defer label_map.deinit();
    {
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionEnd) break;
            if (inst.op == .Label and inst.words.len > 1) label_map.put(inst.words[1], idx) catch {};
        }
    }

    var bc_merge = std.AutoHashMap(usize, u32).init(alloc);
    defer bc_merge.deinit();
    {
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionEnd) break;
            if (inst.op == .SelectionMerge and inst.words.len > 1) {
                const ml = inst.words[1];
                {
                    var j = idx + 1;
                    while (j < m.instructions.len) : (j += 1) {
                        const n = m.instructions[j];
                        if (n.op == .BranchConditional) {
                            bc_merge.put(j, ml) catch {};
                            break;
                        }
                        if (n.op == .Branch or n.op == .ReturnValue or n.op == .Return or n.op == .Kill) break;
                        if (n.op != .Label and n.op != .SelectionMerge and n.op != .LoopMerge) break;
                    }
                }
                {
                    var k = idx + 1;
                    while (k < m.instructions.len) : (k += 1) {
                        const n = m.instructions[k];
                        if (n.op == .Switch) {
                            bc_merge.put(k, ml) catch {};
                            break;
                        }
                        if (n.op == .Branch or n.op == .ReturnValue or n.op == .Return or n.op == .Kill) break;
                        if (n.op != .Label and n.op != .SelectionMerge and n.op != .LoopMerge) break;
                    }
                }
            }
        }
    }

    // Pre-pass: identify loop-header OpPhi (loop counters) — see spirv_to_hlsl.zig.
    var loop_phis = std.AutoHashMap(usize, std.ArrayList(PhiInfo)).init(alloc);
    var phi_hdr = std.AutoHashMap(u32, usize).init(alloc);
    var deferred_hdr = std.AutoHashMap(usize, void).init(alloc);
    var loop_hoists = std.AutoHashMap(usize, std.ArrayList(common.HoistedPhiSrc)).init(alloc);
    var hoisted_ids = std.AutoHashMap(u32, void).init(alloc);
    defer {
        var lpit = loop_phis.valueIterator();
        while (lpit.next()) |list| list.deinit(alloc);
        loop_phis.deinit();
        phi_hdr.deinit();
        deferred_hdr.deinit();
        var lhit = loop_hoists.valueIterator();
        while (lhit.next()) |list| list.deinit(alloc);
        loop_hoists.deinit();
        hoisted_ids.deinit();
        g_loop_phis = null;
        g_phi_hdr = null;
        g_deferred_hdr = null;
        g_loop_hoists = null;
        g_hoisted_ids = null;
        g_materialized_phis = null;
        g_declared_phis = null;
        // Belt-and-braces reset of the loop-recursion depth, per function: the
        // increment's own defer already restores it on both the normal and the
        // error-unwind path, but a threadlocal counter that leaks would silently
        // lower the effective bound for every later shader on this thread. Mirrors
        // spirv_to_glsl.zig.
        g_ewl_depth = 0;
    }
    var materialized_phis = std.AutoHashMap(u32, void).init(alloc);
    defer materialized_phis.deinit();
    g_materialized_phis = &materialized_phis;
    var declared_phis = std.AutoHashMap(u32, void).init(alloc);
    defer declared_phis.deinit();
    g_declared_phis = &declared_phis;
    // #honest-error (cross-scope phi): build the set of loop-MERGE-phi result ids
    // (OpPhis at the top of any loop's merge block). A loop-carried phi whose
    // back-edge UPDATE is one of these is a CROSS-SCOPE phi — the outer loop's
    // carry reads a NESTED loop's exit value, which zioshade's per-region
    // phi-materialization can't resolve (naming conflict between the inner
    // merge-phi and the outer #496 pre-declare → silent-wrong, e.g. nested_loop2,
    // maxdiff 255). Honest-error rather than emit garbage. Narrow by construction:
    // a single loop's back-edge is never its own merge-phi, so only nested-loop
    // cross-scope triggers.
    var merge_phi_results = std.AutoHashMap(u32, void).init(alloc);
    defer merge_phi_results.deinit();
    {
        var mi2: usize = func_idx + 1;
        while (mi2 < m.instructions.len) : (mi2 += 1) {
            const minst2 = m.instructions[mi2];
            if (minst2.op == .FunctionEnd) break;
            if (minst2.op != .LoopMerge or minst2.words.len < 3) continue;
            const mlbl = minst2.words[1];
            const midx2 = label_map.get(mlbl) orelse continue;
            var pj2: usize = midx2 + 1;
            while (pj2 < m.instructions.len) : (pj2 += 1) {
                const pinst2 = m.instructions[pj2];
                if (pinst2.op != .Phi) break;
                merge_phi_results.put(pinst2.words[2], {}) catch {};
            }
        }
    }
    {
        var li = func_idx + 1;
        while (li < m.instructions.len) : (li += 1) {
            const minst = m.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            var hlabel_idx: usize = li;
            while (hlabel_idx > func_idx) : (hlabel_idx -= 1) {
                if (m.instructions[hlabel_idx].op == .Label) break;
            }
            var plist = std.ArrayList(PhiInfo).initCapacity(alloc, 2) catch continue;
            var p = hlabel_idx + 1;
            while (p < li) : (p += 1) {
                const pinst = m.instructions[p];
                if (pinst.op != .Phi or pinst.words.len < 5) continue;
                var init_id: u32 = pinst.words[3];
                var update_id: u32 = if (pinst.words.len >= 6) pinst.words[5] else pinst.words[3];
                var pp: usize = 3;
                while (pp + 1 < pinst.words.len) : (pp += 2) {
                    if (label_map.get(pinst.words[pp + 1])) |lx| {
                        if (lx < hlabel_idx) init_id = pinst.words[pp] else update_id = pinst.words[pp];
                    }
                }
                if (merge_phi_results.contains(update_id)) return error.UnsupportedNestedLoopPhi;
                plist.append(alloc, .{ .result_id = pinst.words[2], .type_id = pinst.words[1], .init_id = init_id, .update_id = update_id }) catch {};
                phi_hdr.put(pinst.words[2], li) catch {};
            }
            loop_phis.put(li, plist) catch plist.deinit(alloc);
            if (li + 1 < m.instructions.len and m.instructions[li + 1].op == .BranchConditional) {
                var d = hlabel_idx + 1;
                while (d < li) : (d += 1) {
                    if (m.instructions[d].op != .Phi) deferred_hdr.put(d, {}) catch {};
                }
            }
        }
    }
    // #413 second pass (after loop_phis/deferred_hdr are complete): find phi
    // update values whose defining instruction lives INSIDE the loop — they
    // are declared after the top-of-loop carry copy that reads them, and in
    // the while-body scope, so their declaration must be hoisted above the
    // loop. Scanning loops in instruction order puts a value shared by nested
    // loops with the OUTERMOST loop, whose scope covers the inner one.
    {
        var li = func_idx + 1;
        while (li < m.instructions.len) : (li += 1) {
            const minst = m.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            const plist = loop_phis.get(li) orelse continue;
            var hlist = std.ArrayList(common.HoistedPhiSrc).initCapacity(alloc, plist.items.len) catch continue;
            for (plist.items) |pi| {
                if (pi.update_id == pi.result_id) continue; // self-carry, no copy emitted
                if (hoisted_ids.contains(pi.update_id)) continue;
                if (!common.loopPhiUpdateNeedsHoist(m.instructions, m.id_defs, &label_map, &deferred_hdr, li, pi.update_id)) continue;
                hoisted_ids.put(pi.update_id, {}) catch continue;
                hlist.append(alloc, .{ .id = pi.update_id, .type_id = pi.type_id }) catch {};
            }
            if (hlist.items.len > 0) {
                loop_hoists.put(li, hlist) catch hlist.deinit(alloc);
            } else {
                hlist.deinit(alloc);
            }
        }
    }
    // #for-loop-init (#482 MSL port): extend the hoist to values the top-of-loop
    // CARRY reads that are defined in the loop HEADER (cond) block. The carry
    // re-emits the continue block at the top of the while-body; a continue
    // operand defined in the header (e.g. the counter OpLoad `%x = OpLoad
    // %counter` living in a Pattern-B cond block, present when the counter is a
    // Function/Private var used past the loop) is emitted in the body AFTER the
    // carry, so the carry reads it out of scope -> Metal rejects ("use of
    // undeclared identifier"). OpPhi header values are pre-declared, so only
    // NON-phi header definitions need this. The #413 pass above only covers phi
    // update ids and skips phi-less loops (`loop_phis.get(li) orelse continue`),
    // so a no-OpPhi Private/Function counter was missed. Mirrors the GLSL/HLSL
    // #for-loop-init hoist (spirv_to_glsl.zig, spirv_to_hlsl.zig), generalised to
    // continue-block operands. Sound because the pre-declared var is assigned at
    // its single header def point and the counter is not modified between that
    // load and the next iteration's continue read (the only modifier is the
    // continue store itself, paired with the next header load).
    {
        var li = func_idx + 1;
        while (li < m.instructions.len) : (li += 1) {
            const minst = m.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            const cont_lbl = minst.words[2]; // OpLoopMerge: words[1]=merge, words[2]=continue
            const cont_idx0 = label_map.get(cont_lbl) orelse continue;
            var hlbl = li;
            while (hlbl > func_idx) : (hlbl -= 1) {
                if (m.instructions[hlbl].op == .Label) break;
            } // header block = (this Label .. the LoopMerge at li)
            var hi = hlbl + 1;
            while (hi < li) : (hi += 1) {
                // Pattern-B header instructions only: those replayed INSIDE the while-body
                // (where the carry can read them out of scope). Pattern-A header instrs are
                // emitted in-place before the LoopMerge; hoisting them would declare below
                // their in-place use. deferred_hdr holds exactly the Pattern-B header instrs.
                if (!deferred_hdr.contains(hi)) continue;
                const hinst = m.instructions[hi];
                if (hinst.op == .Phi) continue; // phis are pre-declared above the loop
                const rid = common.resultIdFromOp(hinst.op, hinst.words) orelse continue; // encoding-correct result id (don't mistake words[2] of a no-result op, e.g. OpStore, for a result)
                if (hoisted_ids.contains(rid)) continue;
                // Does the continue block reference rid? Scan from word 1: no-result ops
                // (OpStore/CopyMemory/AtomicStore) carry operands at words[1..2].
                var referenced = false;
                var ci = cont_idx0 + 1;
                while (ci < m.instructions.len) : (ci += 1) {
                    const cinst = m.instructions[ci];
                    if (cinst.op == .Label or cinst.op == .FunctionEnd or cinst.op == .Branch or cinst.op == .BranchConditional) break;
                    var wi: usize = 1;
                    while (wi < cinst.words.len) : (wi += 1) {
                        if (cinst.words[wi] == rid) {
                            referenced = true;
                            break;
                        }
                    }
                    if (referenced) break;
                }
                if (!referenced) continue;
                if (loop_hoists.getPtr(li)) |e| {
                    e.append(alloc, .{ .id = rid, .type_id = hinst.words[1] }) catch continue;
                } else {
                    var hlist = std.ArrayList(common.HoistedPhiSrc).initCapacity(alloc, 1) catch continue;
                    hlist.append(alloc, .{ .id = rid, .type_id = hinst.words[1] }) catch {
                        hlist.deinit(alloc);
                        continue;
                    };
                    loop_hoists.put(li, hlist) catch {
                        hlist.deinit(alloc);
                        continue;
                    };
                }
                hoisted_ids.put(rid, {}) catch {};
            }
        }
    }
    // #post-loop-header-use: the same hoist, for header values read AFTER the loop.
    //
    // The pass above hoists a Pattern-B header value when the CONTINUE block reads it.
    // A header value read after the loop's merge has the identical problem and was not
    // covered: SPIR-V only requires the definition to dominate the use, and a loop
    // header dominates everything downstream of it, so a value computed in loop 1's
    // header may legally be read inside loop 2. C scoping does not work that way -- the
    // Pattern-B replay puts the definition inside `while (true) { ... }`, which is a
    // sibling scope of loop 2, so the read is out of scope. graphicsfuzz_072 has three
    // sequential loops and computes its exit-test operands in the first one's header,
    // giving six "use of undeclared identifier" errors in both MSL and HLSL.
    //
    // Sound for the same reason as the continue-block case: the loop header always
    // executes when control reaches the loop (the exit test lives inside `while (true)`),
    // so the hoisted variable is assigned before any post-loop read. Pattern-A header
    // instructions are emitted in place ABOVE `while (true)` and are already in scope,
    // which is why this is restricted to deferred_hdr exactly as the pass above is.
    {
        var li = func_idx + 1;
        while (li < m.instructions.len) : (li += 1) {
            const minst = m.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            const merge_idx = label_map.get(minst.words[1]) orelse continue; // words[1] = merge label
            var hlbl = li;
            while (hlbl > func_idx) : (hlbl -= 1) {
                if (m.instructions[hlbl].op == .Label) break;
            }
            var hi = hlbl + 1;
            while (hi < li) : (hi += 1) {
                if (!deferred_hdr.contains(hi)) continue;
                const hinst = m.instructions[hi];
                if (hinst.op == .Phi) continue; // pre-declared by the phi prologue
                const rid = common.resultIdFromOp(hinst.op, hinst.words) orelse continue;
                if (hoisted_ids.contains(rid)) continue;
                // Skip the merge block's leading OpPhis. A merge phi naming this value is
                // NOT a post-loop read: the loop-merge-phi mechanism copies it into the
                // `_lm` variable at the break, inside the loop, where it is in scope.
                // Counting them hoisted seven corpus shaders that did not need it.
                var ci = merge_idx;
                while (ci < m.instructions.len and (m.instructions[ci].op == .Label or m.instructions[ci].op == .Phi)) : (ci += 1) {}
                var referenced = false;
                while (ci < m.instructions.len) : (ci += 1) {
                    if (m.instructions[ci].op == .FunctionEnd) break;
                    const cw = m.instructions[ci].words;
                    var wi: usize = 1;
                    while (wi < cw.len) : (wi += 1) {
                        if (cw[wi] == rid) {
                            referenced = true;
                            break;
                        }
                    }
                    if (referenced) break;
                }
                if (!referenced) continue;
                if (loop_hoists.getPtr(li)) |e| {
                    e.append(alloc, .{ .id = rid, .type_id = hinst.words[1] }) catch continue;
                } else {
                    var hlist = std.ArrayList(common.HoistedPhiSrc).initCapacity(alloc, 1) catch continue;
                    hlist.append(alloc, .{ .id = rid, .type_id = hinst.words[1] }) catch {
                        hlist.deinit(alloc);
                        continue;
                    };
                    loop_hoists.put(li, hlist) catch {
                        hlist.deinit(alloc);
                        continue;
                    };
                }
                hoisted_ids.put(rid, {}) catch {};
            }
        }
    }
    g_loop_phis = &loop_phis;
    g_phi_hdr = &phi_hdr;
    g_deferred_hdr = &deferred_hdr;
    g_loop_hoists = &loop_hoists;
    g_hoisted_ids = &hoisted_ids;

    // Phi-variable prologue: every materialized phi variable is declared ONCE here, at
    // function scope, instead of at whichever construct happens to reach it first.
    //
    // The emitter can traverse one source region more than once -- an enclosing loop's
    // pre-scan walks phis that belong to a nested loop or switch -- and it reaches those
    // regions at different nesting depths. Declaring at the point of use therefore gave
    // either a redefinition (two declarations landing in one scope, graphicsfuzz_041) or
    // an out-of-scope reference (the surviving declaration landing in a sibling block,
    // graphicsfuzz_001). Hoisting makes both structurally impossible: one declaration,
    // visible to every assignment and every read. A phi that never gets materialized
    // leaves an unused local, which Metal accepts.
    //
    // Two exclusions, both of which have their own declaration mechanism and their own
    // name: #413-hoisted ids (declared above the loop by the hoist) and loop-carried
    // header phis (declared as plain `vN` by tryEmitLoopPhiDeclMSL).
    {
        var pi = func_idx + 1;
        while (pi < m.instructions.len) : (pi += 1) {
            const pinst = m.instructions[pi];
            if (pinst.op == .FunctionEnd) break;
            if (pinst.op != .Phi or pinst.words.len < 3) continue;
            const rid = pinst.words[2];
            if (hoisted_ids.contains(rid)) continue;
            if (phi_hdr.get(rid) != null) continue;
            const t = mslValueType(m, pinst.words[1], names, alloc) catch continue;
            try w.print("    {s} {s};\n", .{ t, mslPhiVarName(names, rid, alloc) });
            if (g_declared_phis) |dp| dp.put(rid, {}) catch {};
        }
    }

    var idx = func_idx + 1;
    while (idx < m.instructions.len) : (idx += 1) {
        const inst = m.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (isDeferredHdrMSL(idx)) continue;
        if (try tryEmitLoopPhiDeclMSL(m, names, inst, w, alloc, "    ")) continue;
        if (inst.op == .FunctionParameter or inst.op == .Label or inst.op == .SelectionMerge or inst.op == .Branch) continue;

        // Handle LoopMerge: emit while(true) { condition; if(!cond) break; body; }
        if (inst.op == .LoopMerge and inst.words.len >= 3) {
            const merge_lbl = inst.words[1];
            const cont_lbl = inst.words[2];
            idx = try emitWhileLoopMSL(m, names, decs, idx, merge_lbl, cont_lbl, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, cbuffers, textures, storage_buffers, arraylen_buf_index);
            continue;
        }

        if (inst.op == .BranchConditional) {
            if (inst.words.len < 4) continue;
            const cn = names.get(inst.words[1]) orelse "c";
            const tl = inst.words[2];
            const fl = if (inst.words.len > 3) inst.words[3] else null;
            const ml = bc_merge.get(idx);
            if (ml) |mval| {
                const he = fl != null and fl.? != mval;
                // Materialize selection-merge phis: a value that differs by branch
                // (`x = cond ? a : b`) lowers to an OpPhi at the merge. MSL has block
                // scope, so the branch-local temp is out of scope after the `if`;
                // declare a persistent `_phi` var, assign the branch value in each
                // arm, and rename the phi id to it. Without this the post-merge use
                // references an undeclared identifier (Metal rejects it).
                var mphis: std.ArrayList(MslMergePhi) = .empty;
                defer mphis.deinit(alloc);
                collectMergePhis(m, &label_map, mval, &mphis, alloc);
                for (mphis.items) |pv| {
                    const t = try mslValueType(m, pv.type_id, names, alloc);
                    const vn = mslPhiVarName(names, pv.result_id, alloc);
                    // An enclosing construct may already have declared this variable
                    // (mslPhiDeclare). Drop the type and keep the initializer as a plain
                    // assignment -- skipping it outright would leave the phi undefined on
                    // the fall-through path.
                    const ty: []const u8 = if (mslPhiDeclare(pv.result_id)) t else "";
                    const sep: []const u8 = if (ty.len > 0) " " else "";
                    if (he) {
                        // Both arms assign it; declare uninitialized.
                        if (ty.len > 0) try w.print("    {s} {s};\n", .{ ty, vn });
                    } else {
                        // No else arm: the fall-through value is the incoming from the
                        // header block (in scope before the `if`); initialize to it so
                        // the phi is defined when the condition is false.
                        const false_val = if (mslPhiPred1InTrueRegion(m, &label_map, tl, mval, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                        const fvn = mslExprName(m, names, false_val, alloc);
                        try w.print("    {s}{s}{s} = {s};\n", .{ ty, sep, vn, fvn });
                    }
                }
                try w.print("    if ({s})\n    {{\n", .{cn});
                idx = try emitBlock(m, names, decs, tl, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                for (mphis.items) |pv| {
                    const vn = mslPhiVarName(names, pv.result_id, alloc);
                    const true_val = if (mslPhiPred1InTrueRegion(m, &label_map, tl, mval, pv.preds[1], alloc)) pv.vals[1] else pv.vals[0];
                    try w.print("        {s} = {s};\n", .{ vn, mslExprName(m, names, true_val, alloc) });
                }
                if (he) {
                    try w.writeAll("    } else {\n");
                    idx = try emitBlock(m, names, decs, fl.?, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                    for (mphis.items) |pv| {
                        const vn = mslPhiVarName(names, pv.result_id, alloc);
                        const false_val = if (mslPhiPred1InTrueRegion(m, &label_map, tl, mval, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                        try w.print("        {s} = {s};\n", .{ vn, mslExprName(m, names, false_val, alloc) });
                    }
                }
                try w.writeAll("    }\n");
                for (mphis.items) |pv| {
                    const pn = mslPhiVarName(names, pv.result_id, alloc);
                    if (names.fetchPut(pv.result_id, pn) catch null) |old| alloc.free(old.value);
                    if (g_materialized_phis) |mp| mp.put(pv.result_id, {}) catch {};
                }
                if (label_map.get(mval)) |mi| {
                    idx = mi;
                }
            } else {
                // Unstructured control flow (OpBranchConditional without
                // OpSelectionMerge). The convergence-guessing reconstruction is
                // silent-wrong (can mis-nest / drop branches); fail loud. zioshade's
                // own frontend always emits merge info. Backlog #4 (G2) =
                // structurize. Mirrors the GLSL backend (#88).
                return error.UnstructuredControlFlow;
            }
            continue;
        }

        if (inst.op == .Switch) {
            if (inst.words.len < 3) continue;
            const sn = names.get(inst.words[1]) orelse "s";
            const dl = inst.words[2];
            const ml = bc_merge.get(idx);
            if (ml) |mval| {
                // #477: materialize switch-merge phis (N incoming) as `_phi` vars.
                var sphis: std.ArrayList(Instruction) = .empty;
                defer sphis.deinit(alloc);
                collectSwitchMergePhis(m, &label_map, mval, &sphis, alloc);
                const is_ft = switchIsFallthrough(m, inst, mval, &label_map);
                // #switch-fallthrough: collect cross-case chain phis.
                var chain_entries: std.ArrayList(ChainPhiEntry) = .empty;
                defer chain_entries.deinit(alloc);
                if (is_ft) collectSwitchChainPhis(m, inst, mval, &label_map, &chain_entries, alloc);
                // Rename + declare merge phis AND chain phis (both use _phi naming).
                finalizeSwitchPhis(names, sphis.items, alloc);
                for (chain_entries.items) |ce| {
                    const pn = mslPhiVarName(names, ce.phi.words[2], alloc);
                    if (names.fetchPut(ce.phi.words[2], pn) catch null) |old| alloc.free(old.value);
                    if (g_materialized_phis) |mp| mp.put(ce.phi.words[2], {}) catch {};
                }
                try emitSwitchPhiDecls(m, names, sphis.items, w, alloc);
                for (chain_entries.items) |ce| {
                    // #switch-merge-phi-hoist-shadow: same exclusion as
                    // emitSwitchPhiDecls - a #413-hoisted id is already declared
                    // above the enclosing loop under this name; redeclaring here
                    // shadows it and the case copies write the wrong variable.
                    if (g_hoisted_ids) |h| if (h.contains(ce.phi.words[2])) continue;
                    if (!mslPhiDeclare(ce.phi.words[2])) continue;
                    const t = try mslValueType(m, ce.phi.words[1], names, alloc);
                    const vn = mslPhiVarName(names, ce.phi.words[2], alloc);
                    try w.print("    {s} {s};\n", .{ t, vn });
                }
                // Entry inits: for each chain phi at case C, if(sel==C) chain_phi=initial.
                if (chain_entries.items.len > 0) {
                    for (chain_entries.items) |ce| {
                        const vn = mslPhiVarName(names, ce.phi.words[2], alloc);
                        try w.print("    if ({s} == {d}) {{ {s} = {s}; }}\n", .{ sn, ce.literal, vn, mslExprName(m, names, ce.entry_value, alloc) });
                    }
                }
                const saved_switch_ctx = g_switch_ctx;
                const saved_chain = g_switch_chain;
                g_switch_ctx = .{ .merge_label = mval, .phis = sphis.items };
                g_switch_chain = if (is_ft) chain_entries.items else null;
                try w.print("    switch ({s}) {{\n", .{sn});
                // Cases FIRST, default LAST: a case whose body OpBranches to the default
                // label (SPIR-V fallthrough INTO default) needs default below it in source
                // order for C-fallthrough to reach it. The old default-first order made
                // such a case fall off the switch end (fallthrough_then_break: sel=0 lost
                // the default body). Mirrors spirv-cross + the GLSL/HLSL fix.
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const cv = inst.words[wi];
                    const target = inst.words[wi + 1];
                    if (target == mval) continue;
                    try w.print("    case {d}: {{\n", .{switchCaseLiteral(m, inst.words[1], cv)});
                    // Buffered so the trailing `break;` below can be skipped when the body
                    // already left the switch on its own (#dead-case-break).
                    var cb: std.ArrayList(u8) = .empty;
                    defer cb.deinit(alloc);
                    _ = try emitBlock(m, names, decs, target, mval, &label_map, &bc_merge, compat.listWriter(&cb, alloc), alloc, is_frag, output_var_id, "    ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                    try emitSwitchPhiCaseCopy(m, names, sphis.items, target, compat.listWriter(&cb, alloc), alloc);
                    try w.writeAll(cb.items);
                    // #switch-fallthrough: omit break if this case falls through to
                    // another case target (the cross-case chain accumulates).
                    var falls_through = false;
                    if (is_ft) {
                        const tidx = label_map.get(target) orelse m.instructions.len;
                        var ri2: usize = tidx + 1;
                        while (ri2 < m.instructions.len) : (ri2 += 1) {
                            const rinst2 = m.instructions[ri2];
                            if (rinst2.op == .Label or rinst2.op == .FunctionEnd or rinst2.op == .BranchConditional) break;
                            if (rinst2.op == .Branch and rinst2.words.len > 1) {
                                if (rinst2.words[1] != mval and rinst2.words[1] != target and isSwitchCaseTarget(inst, rinst2.words[1])) falls_through = true;
                                break;
                            }
                        }
                    }
                    if (!falls_through and !caseBodyTerminates(cb.items)) try w.writeAll("    break;\n");
                    try w.writeAll("    }\n");
                }
                if (dl != mval) {
                    try w.writeAll("    default: {\n");
                    var db: std.ArrayList(u8) = .empty;
                    defer db.deinit(alloc);
                    _ = try emitBlock(m, names, decs, dl, mval, &label_map, &bc_merge, compat.listWriter(&db, alloc), alloc, is_frag, output_var_id, "    ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                    try emitSwitchPhiCaseCopy(m, names, sphis.items, dl, compat.listWriter(&db, alloc), alloc);
                    try w.writeAll(db.items);
                    if (!caseBodyTerminates(db.items)) try w.writeAll("    break;\n");
                    try w.writeAll("    }\n");
                }
                try w.writeAll("    }\n");
                g_switch_ctx = saved_switch_ctx;
                g_switch_chain = saved_chain;
                if (label_map.get(mval)) |mi| {
                    idx = mi;
                }
            } else {
                // Unstructured control flow (OpSwitch without OpSelectionMerge).
                // The convergence-guessing reconstruction is silent-wrong (drops
                // the default case / elides the switch); fail loud. Mirrors the
                // GLSL backend (#88). Backlog #4 (G2) = structurize.
                return error.UnstructuredControlFlow;
            }
            continue;
        }

        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, output_var_id, cbuffers, textures, storage_buffers, arraylen_buf_index);
    }
}

// #selfloop: MSL twin of spirv_to_glsl.zig's emitSelfLoopBodyHeaderGLSL. Lower a
// self-loop whose continue target IS its own header (body in the header before the
// LoopMerge; back-edge is the BranchConditional that follows). Emit the straight-line
// header body ONCE in while(true), lower the back-edge to
// `if (!(cond)) break; <phi back-edge updates>`. Phi inits are hoisted above the loop
// by the existing machinery (tryEmitLoopPhiDeclMSL, reached before the LoopMerge).
// Honest-error unless the header is straight-line and the back-edge's continue arm is
// its true target. Returns the index of the merge block.
fn emitSelfLoopBodyHeaderMSL(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    loop_idx: usize,
    merge_lbl: u32,
    hlbl_idx: usize,
    back_edge: Instruction,
    label_map: *const std.AutoHashMap(u32, usize),
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    ovid: ?u32,
    cbuffers: *const std.ArrayList(CbufferDecl),
    textures: *const std.ArrayList(TextureDecl),
    storage_buffers: *const std.ArrayList(CbufferDecl),
    arraylen_buf_index: *const std.AutoHashMap(u32, u32),
) !usize {
    // The header body must be straight-line (no nested merge/switch/branch).
    var hi: usize = hlbl_idx + 1;
    while (hi < loop_idx) : (hi += 1) {
        switch (m.instructions[hi].op) {
            .LoopMerge, .Switch, .SelectionMerge, .Branch, .BranchConditional => return error.CrossCompileUnsupported,
            else => {},
        }
    }
    // Back-edge polarity: true target must be the header (continue) -> `if (!(cond)) break;`.
    if (back_edge.words[2] != m.instructions[hlbl_idx].words[1]) return error.CrossCompileUnsupported;

    // The loop body = the header's straight-line instructions, ONCE (Phi skipped -- the
    // main emission loop already hoisted+initialized each header phi above the loop via
    // tryEmitLoopPhiDeclMSL; re-declaring would duplicate, and decl-in-loop would re-zero
    // the counter each iteration -> infinite loop).
    try w.writeAll("    while (true)\n    {\n");
    var bi: usize = hlbl_idx + 1;
    while (bi < loop_idx) : (bi += 1) {
        const inst = m.instructions[bi];
        if (inst.op == .Phi or inst.op == .Label) continue;
        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
    }

    // Lower the back-edge BranchConditional (true->header=continue, false->merge=break)
    // to `if (!(cond)) break;` then the phi back-edge updates on the continue path.
    const cond_name = names.get(back_edge.words[1]) orelse "true";
    try w.print("        if (!({s})) break;\n", .{cond_name});
    if (g_loop_phis) |lp| {
        if (lp.get(loop_idx)) |plist| {
            for (plist.items) |pi| {
                if (pi.update_id == pi.result_id) continue; // self-carry, no copy
                const rname = names.get(pi.result_id) orelse continue;
                const uname = names.get(pi.update_id) orelse continue;
                try w.print("        {s} = {s};\n", .{ rname, uname });
            }
        }
    }
    try w.writeAll("    }\n");

    return label_map.get(merge_lbl) orelse (loop_idx + 2);
}

/// #shortcircuit-loop-cond: the chain verifier lives in spirv_cross_common
/// (shared with the GLSL/HLSL ports -- single source, no per-backend drift).
fn shortCircuitChainReachesMergeMSL(
    m: *const ParsedModule,
    chain_head: u32,
    merge_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
) bool {
    return common.shortCircuitChainReachesMerge(m, chain_head, merge_lbl, label_map);
}

// #loop-break-out-of-switch: does any OpBranch/OpBranchConditional in
// [start_idx, end_idx) target `sw_merge` (the enclosing switch's merge)? Only a
// heuristic arming decision for the flag lowering: a false negative keeps the old
// behavior (nothing regresses), a false positive costs one unused bool. Valid
// structured SPIR-V never has such a branch inside a loop region, so on the real
// corpus this is always false.
fn loopRegionBreaksToSwitchMSL(m: *const ParsedModule, start_idx: usize, end_idx: usize, sw_merge: u32) bool {
    var i = start_idx;
    while (i < end_idx and i < m.instructions.len) : (i += 1) {
        const t = m.instructions[i];
        if (t.op == .Branch and t.words.len > 1 and t.words[1] == sw_merge) return true;
        if (t.op == .BranchConditional) {
            if (t.words.len > 2 and t.words[2] == sw_merge) return true;
            if (t.words.len > 3 and t.words[3] == sw_merge) return true;
        }
    }
    return false;
}

// #switch-arm-break + #loop-break-out-of-switch: emit, at a branch site whose
// target is the enclosing switch's merge, the switch-merge phi copy for
// predecessor block `pred_lbl`, the armed-loop flag set (when inside one), and
// the `break;`. Used by the BranchConditional arm sites in emitBlock and
// emitWhileLoopMSL's body walker.
fn emitSwitchMergeBreakMSL(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    sctx: SwitchPhiCtx,
    pred_lbl: u32,
    indent: []const u8,
    w: anytype,
    alloc: std.mem.Allocator,
) !void {
    for (sctx.phis) |phi| try emitMergePhiCopyForPred(m, names, phi, pred_lbl, indent, w, alloc);
    if (g_swbrk_flag) |f| try w.print("{s}{s} = true;\n", .{ indent, f });
    try w.print("{s}break;\n", .{indent});
}

/// #loopcond-not-exit: does the loop body (from `body_lbl` to the continue/merge
/// labels) contain ANY branch whose target is the loop merge? A no-top-test
/// while(true) needs at least one exit; verify before lowering.
fn loopBodyReachesMergeMSL(
    m: *const ParsedModule,
    body_lbl: u32,
    merge_lbl: u32,
    cont_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
) bool {
    const start = label_map.get(body_lbl) orelse return false;
    var i: usize = start + 1;
    while (i < m.instructions.len) : (i += 1) {
        const inst = m.instructions[i];
        if (inst.op == .FunctionEnd) return false;
        if (inst.op == .Label and inst.words.len > 1 and (inst.words[1] == cont_lbl or inst.words[1] == merge_lbl)) return false;
        if ((inst.op == .Branch or inst.op == .BranchConditional) and inst.words.len > 1) {
            var wi: usize = if (inst.op == .Branch) 1 else 2;
            while (wi < inst.words.len) : (wi += 1) {
                if (inst.words[wi] == merge_lbl) return true;
            }
        }
    }
    return false;
}

fn emitWhileLoopMSL(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    loop_idx: usize,
    merge_lbl: u32,
    cont_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
    bc_merge: *const std.AutoHashMap(usize, u32),
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    ovid: ?u32,
    cbuffers: *const std.ArrayList(CbufferDecl),
    textures: *const std.ArrayList(TextureDecl),
    storage_buffers: *const std.ArrayList(CbufferDecl),
    arraylen_buf_index: *const std.AutoHashMap(u32, u32),
) !usize {
    g_ewl_depth += 1;
    defer g_ewl_depth -= 1;
    if (g_ewl_depth > max_emit_while_depth) return error.CrossCompileUnsupported;
    // #413: declare loop-carried phi update temps ABOVE the loop. The top-of-
    // loop carry copy (#237) reads them on every iteration after the first;
    // without the hoist the declaration sits later in the body (and in the
    // while-body scope), so the copy read an undeclared identifier. Emitted
    // before the early-out paths below because the defining instructions
    // strip their declaration unconditionally once an id is in the hoist set.
    if (g_loop_hoists) |lh| {
        if (lh.get(loop_idx)) |hlist| {
            for (hlist.items) |h| {
                if (names.get(h.id) == null) {
                    const nm = std.fmt.allocPrint(alloc, "v{d}", .{h.id}) catch "vhoist";
                    if (names.fetchPut(h.id, nm) catch null) |old| alloc.free(old.value);
                }
                const tyname = try mslType(m, h.type_id, names, alloc);
                try w.print("    {s} {s};\n", .{ tyname, names.get(h.id) orelse "vhoist" });
            }
        }
    }

    // Two patterns after LoopMerge:
    // Pattern A: LoopMerge; Branch cond_label; ...; BranchConditional cond, body, merge
    // Pattern B: LoopMerge; BranchConditional cond, body, merge (merged condition)

    var bc_idx: usize = loop_idx + 1;
    var cond_start: ?usize = null;
    var cond_end: usize = loop_idx + 1;
    var is_do_while = false; // pattern C: condition tested at the back-edge (do-while)
    var dw_loop_when_true = true;
    // #shortcircuit-loop-cond: the loop's top test is a short-circuit chain lowered
    // structurally (while(true) + guarded break at the chain's final branch). The
    // body walk then starts at the chain head instead of a condition block.
    var no_top_test = false;
    var sc_chain_head: u32 = 0;

    if (loop_idx + 1 >= m.instructions.len) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }

    // Header label = nearest Label before the LoopMerge (needed for do-while
    // back-edge detection).
    var hlbl_idx: usize = loop_idx;
    while (hlbl_idx > 0) : (hlbl_idx -= 1) {
        if (m.instructions[hlbl_idx].op == .Label) break;
    }
    const header_lbl: u32 = if (m.instructions[hlbl_idx].words.len > 1) m.instructions[hlbl_idx].words[1] else 0;

    const next_inst = m.instructions[loop_idx + 1];
    // #selfloop: OpLoopMerge %merge %hdr where the continue target IS the loop
    // header (the body sits in the header before the LoopMerge). The generic body
    // emitter mishandles it (re-enters the header's own LoopMerge / miscomputes the
    // cond -> UnsupportedOpcode). Lower it directly instead, mirroring spirv-cross
    // and the GLSL emitSelfLoopBodyHeaderGLSL twin. (Pattern B only.)
    if (cont_lbl == header_lbl and next_inst.op == .BranchConditional and next_inst.words.len >= 4) {
        return try emitSelfLoopBodyHeaderMSL(m, names, decs, loop_idx, merge_lbl, hlbl_idx, next_inst, label_map, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
    }
    if (next_inst.op == .Branch and next_inst.words.len >= 2) {
        // FIRST: is this a do-while (bottom-test) loop? Inspect the CONTINUE block's
        // terminator BEFORE scanning the body. Otherwise the body's own `if`
        // BranchConditional (`if(x) continue;`) is mis-grabbed as the loop condition,
        // which crashes / silently miscompiles (inverted polarity, dup temps) — #244.
        if (common.detectDoWhileBackEdge(m, cont_lbl, header_lbl, merge_lbl, label_map)) |dw_bc| {
            is_do_while = true;
            bc_idx = dw_bc;
            cond_start = null;
        } else {
            // Pattern A: separate top-test condition block.
            const cond_lbl = next_inst.words[1];
            const cond_idx = label_map.get(cond_lbl) orelse {
                if (label_map.get(merge_lbl)) |mi| return mi;
                return loop_idx + 1;
            };
            cond_start = cond_idx + 1;
            bc_idx = cond_idx + 1;
            while (bc_idx < m.instructions.len) : (bc_idx += 1) {
                const scan = m.instructions[bc_idx];
                if (scan.op == .BranchConditional) break;
                if (scan.op == .Branch or scan.op == .FunctionEnd or scan.op == .Label) {
                    bc_idx = m.instructions.len;
                    break;
                }
            }
            if (bc_idx >= m.instructions.len) {
                // #dowhile-compound-cond: a do-while whose continue block has a nested
                // OpSelectionMerge (a short-circuit && / || loop condition) reaches here:
                // detectDoWhileBackEdge returned null (the continue is not a single-block
                // back-edge) and Pattern A found no top-test condition. Previously this
                // silently DROPPED the entire loop. Honest-error instead. (Single-level short-circuit
                // is now lowered end-to-end: detectDoWhileBackEdge follows the nested SelectionMerge
                // to the real back-edge and tryInlineDoWhileCond rebuilds the OpPhi-of-bools cond;
                // this floor is reached only when detectDoWhileBackEdge STILL returns null -- shapes
                // its single-level SelectionMerge descent cannot handle. #77)
                if (label_map.get(cont_lbl)) |cidx| {
                    var sci: usize = cidx + 1;
                    while (sci < m.instructions.len) : (sci += 1) {
                        const t = m.instructions[sci];
                        if (t.op == .SelectionMerge) return error.UnsupportedDoWhileCompoundCond;
                        if (t.op == .Label or t.op == .FunctionEnd or t.op == .Branch) break;
                    }
                }
                if (label_map.get(merge_lbl)) |mi| return mi;
                return loop_idx + 1;
            }
            cond_end = bc_idx;
            // #loopcond-not-exit: the BranchConditional found in the "condition block"
            // is only the loop's top test if one of its targets IS the loop merge. When
            // neither is, the block is not a condition block at all -- it is the first
            // block of a SHORT-CIRCUIT chain (`while (a && b)`), whose OpSelectionMerge
            // sits right above the branch and whose real exit test lives further down.
            //
            // Treating it as the top test emits `if (!(a)) break;`, silently DROPPING the
            // second operand, and leaves the chain's merge phi with no assignment: on
            // graphicsfuzz_001 that produced `bool v56_phi;` declared, read twice, and
            // never written. It compiled cleanly (the phi prologue declares it), so no
            // compile-only gate could see it -- a silent-wrong, not a diagnosable one.
            //
            // Lowering this shape is the NO-TOP-TEST form: `while (true)` with the chain
            // emitted as ordinary nested selections (their bool phis materialized per
            // arm by the standard #474 machinery) and the chain's FINAL
            // BranchConditional -- the one whose target IS the loop merge -- lowered as
            // the guarded break (see the body walker's #shortcircuit-exit rule). Verify
            // the chain actually terminates at such a branch first; a chain that never
            // reaches the merge would emit an exit-less loop, so that shape still
            // honest-errors. (graphicsfuzz_001 and _068 are the corpus instances.)
            var is_chain = false;
            const sbc = m.instructions[bc_idx];
            if (sbc.words.len >= 4 and sbc.words[2] != merge_lbl and sbc.words[3] != merge_lbl and
                bc_idx > 0 and m.instructions[bc_idx - 1].op == .SelectionMerge and m.instructions[bc_idx - 1].words.len > 1)
            {
                // The selection's merge block starting with a BOOL OpPhi is what makes this
                // a short-circuit chain rather than an ordinary `if` in the first body
                // block: that phi IS the combined condition. Without this check the guard
                // also rejected the `do { if (c) break; ... } while(false)` idiom, whose
                // first block looks identical up to here but whose merge carries no bool
                // phi (selection-block-dominator).
                if (label_map.get(m.instructions[bc_idx - 1].words[1])) |smi| {
                    if (smi + 1 < m.instructions.len) {
                        const sphi = m.instructions[smi + 1];
                        if (sphi.op == .Phi and sphi.words.len > 1) {
                            if (getDef(m, sphi.words[1])) |td| {
                                if (td.op == .TypeBool) is_chain = true;
                            }
                        }
                    }
                    if (is_chain) {
                        if (shortCircuitChainReachesMergeMSL(m, cond_lbl, merge_lbl, label_map)) {
                            no_top_test = true;
                            sc_chain_head = cond_lbl;
                        } else return error.UnsupportedShortCircuitLoopCond;
                    } else {
                        // #loopcond-not-exit (general form, mirror of GLSL): a cond-block
                        // BranchConditional whose targets are NEITHER the loop merge is
                        // NOT the exit test -- it is the FIRST STATEMENT of the body
                        // (graphicsfuzz_017's `if (y<30) { ...; break; } else { ... }`
                        // loop; taking it as the top test INVERTS the loop). Lower as
                        // no-top-test; verify the body reaches the merge or refuse.
                        if (loopBodyReachesMergeMSL(m, cond_lbl, merge_lbl, cont_lbl, label_map) and !common.continueRegionHasExit(m, cont_lbl, merge_lbl, label_map)) {
                            no_top_test = true;
                            sc_chain_head = cond_lbl;
                        } else return error.UnsupportedLoopCondBlock;
                    }
                }
            }
        }
    } else if (next_inst.op == .BranchConditional and next_inst.words.len >= 4) {
        // Pattern B
        bc_idx = loop_idx + 1;
        cond_start = null;
        cond_end = loop_idx + 1;
    } else {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }

    const bc = m.instructions[bc_idx];
    if (bc.words.len < 4) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }
    var body_lbl = bc.words[2];
    // #shortcircuit-loop-cond: with the top test deferred to the chain's final branch,
    // the "body" walk starts at the CHAIN HEAD -- the walker lowers each chain link as
    // an ordinary selection (bool phi materialized per arm) and the final branch to the
    // merge as the guarded break (#shortcircuit-exit rule below).
    if (no_top_test) body_lbl = sc_chain_head;

    // #246: do-while emission. STRAIGHT-LINE body → keep `while(true){ body; if(!cond)break; }`.
    // Body WITH control flow → native `do { body } while(<inlined cond>);` when the back-edge
    // condition can be rebuilt over persistent vars (so a body `continue` re-evaluates it at
    // the bottom test, outside the body block scope). Else honest-error.
    var body_has_cf = false;
    var body_nested = false; // #dowhile-nested-body: nested loop/switch -> native do-while
    var dw_inlined: ?[]const u8 = null;
    if (is_do_while) {
        body_lbl = next_inst.words[1]; // OpBranch target = body
        dw_loop_when_true = (bc.words[2] == header_lbl);

        const bidx = label_map.get(body_lbl) orelse m.instructions.len;
        // #dowhile-nested-body: PRE-SCAN the body region (body -> continue label)
        // for a nested loop/switch BEFORE the strict trivial-body validation: the
        // strict scan rejects a branch into the nested region (a target that is
        // neither the continue nor the merge) before it could ever reach the
        // nested LoopMerge. A nested body routes to the NATIVE do-while (its body
        // emission runs through the full walker, and a body continue re-evaluates
        // the test -- pattern C skips it, fixture-proven miscompile).
        {
            var pidx = bidx + 1;
            while (pidx < m.instructions.len) : (pidx += 1) {
                const t = m.instructions[pidx];
                if (t.op == .Label and t.words.len > 1 and t.words[1] == cont_lbl) break;
                if (t.op == .FunctionEnd) break;
                if (t.op == .LoopMerge or t.op == .Switch) {
                    body_nested = true;
                    break;
                }
            }
        }
        var sidx = bidx + 1;
        while (!body_nested and sidx < m.instructions.len) : (sidx += 1) {
            const t = m.instructions[sidx];
            if (t.op == .Label and t.words.len > 1 and t.words[1] == cont_lbl) break;
            if (t.op == .FunctionEnd) break;
            // Nested loop or switch sharing the do-while condition is not yet supported.
            if (t.op == .LoopMerge or t.op == .Switch) return error.UnstructuredControlFlow;
            // if/continue/break in the body — supported via the native do-while path.
            if (t.op == .SelectionMerge or t.op == .BranchConditional) body_has_cf = true;
            // A branch to anything other than the continue (back-edge) or merge (`break`)
            // is unstructured for this flat scan — fail loud (conservative; only trivial
            // if(c)continue;/break; bodies are accepted in this increment).
            if (t.op == .Branch and t.words.len > 1 and t.words[1] != cont_lbl and t.words[1] != merge_lbl) return error.UnstructuredControlFlow;
        }
        // #77: a compound (short-circuit && / ||) back-edge condition is an OpPhi of two
        // bools at the selection-merge block (the continue block has a nested
        // OpSelectionMerge). Rebuild it as an inline expression for BOTH straight-line
        // and control-flow-bearing bodies so the native do-while path can emit
        // `do { body } while(<cond>);`. If a phi cond cannot be rebuilt, fail LOUD:
        // the straight-line break-test path would otherwise read an unmaterialised phi
        // (silent-wrong — the hazard that kept #77 honest-errored until S1+S2 landed).
        // #dowhile-nested-body: the native path is only verified for phi-free
        // do-whiles (the _lm/latch/carry machinery was never exercised here; _027
        // emits use-before-declaration merge-phi copies under pattern C). Keep the
        // honest error when any of those phi surfaces exists.
        if (body_nested and !common.dowhileNestedBodyPhiSafe(m, loop_idx, merge_lbl, cont_lbl, label_map, true)) {
            return error.UnsupportedDoWhileNestedBody;
        }
        const cond_is_phi = if (getDef(m, bc.words[1])) |cdef| cdef.op == .Phi else false;
        if (cond_is_phi) {
            dw_inlined = common.tryInlineDoWhileCond(m, names, bc.words[1], label_map, alloc, std450ToMsl) orelse return error.UnsupportedDoWhileCompoundCond;
        } else if (body_has_cf or body_nested) {
            dw_inlined = common.tryInlineDoWhileCond(m, names, bc.words[1], label_map, alloc, std450ToMsl) orelse return error.UnstructuredControlFlow;
        }
    }
    const dw_native = dw_inlined != null;

    // #loop-merge-phi: collect DIVERGENT phis at the loop's merge block (top-test
    // loops only; do-while keeps the current behavior). Such a phi's correct
    // post-loop value depends on which exit path was taken (normal exit vs break);
    // see collectLoopMergePhis. Also resolve the normal-exit predecessor (the
    // smallest-index pred: the header/cond block precedes every body/break block).
    var loop_mphis: std.ArrayList(Instruction) = .empty;
    defer loop_mphis.deinit(alloc);
    var lm_norm_pred: u32 = 0;
    if (!is_do_while) {
        collectLoopMergePhis(m, label_map, merge_lbl, &loop_mphis, alloc);
        if (loop_mphis.items.len > 0) {
            var min_idx: usize = std.math.maxInt(usize);
            var pi: usize = 3;
            while (pi + 1 < loop_mphis.items[0].words.len) : (pi += 2) {
                const pred = loop_mphis.items[0].words[pi + 1];
                if (label_map.get(pred)) |pidx| {
                    if (pidx < min_idx) {
                        min_idx = pidx;
                        lm_norm_pred = pred;
                    }
                }
            }
        }
    }

    // #continue/latch: divergent phis at the loop's CONTINUE/latch block. The latch
    // is reached from BOTH the continue path(s) AND the body fall-through, so a
    // latch phi's value depends on which path took it — it must be assigned at each
    // (continue + fall-through), or the loop-carried var it feeds stays stale
    // (loop-continue-break: count/sum read via uninitialized latch-phi temps,
    // maxdiff 255). i's back-edge is a plain computation in the latch (not a phi),
    // so it is unaffected. Mirrors loop_mphis (merge) via the same mechanism.
    var latch_mphis: std.ArrayList(Instruction) = .empty;
    defer latch_mphis.deinit(alloc);
    if (!is_do_while) collectLoopMergePhis(m, label_map, cont_lbl, &latch_mphis, alloc);

    // #237: run the SSA phi counter update at the TOP of the loop (first-iteration
    // flag) so a `continue` still advances the counter (matching a real `for`).
    var fbuf: [40]u8 = undefined;
    const first_flag = std.fmt.bufPrint(&fbuf, "_loopfirst_{d}", .{loop_idx}) catch "_loopfirst";
    // do-while loops carry their update in the body and test at the bottom.
    const has_phis = !is_do_while and (if (g_loop_phis) |lp| (if (lp.get(loop_idx)) |pl| pl.items.len > 0 else false) else false);
    // #loop-continue-deadincr (#237 generalized): emit the counter update at the TOP
    // of the loop for ALL top-test loops (!is_do_while), not just phi-counter loops. A
    // body `continue;` must advance the counter (matching a real `for`); when the
    // increment sat at the BOTTOM (the old !has_phis path), `continue;` skipped it ->
    // the counter never advanced -> infinite loop (lut_palette et al., maxdiff 255,
    // found via prove_naga on unoptimized SPIR-V; masked by spirv-opt -O, which lowers
    // to the phi/do-while form). has_phis still gates the SelectionMerge honest-error.
    if (!is_do_while) try w.print("    bool {s} = true;\n", .{first_flag});

    // #loop-merge-phi: declare a distinct var per divergent merge phi (read after
    // the loop) + rename its result id so the generic OpPhi handler does not
    // re-alias it to a single incoming.
    for (loop_mphis.items) |phi| {
        const t = try mslValueType(m, phi.words[1], names, alloc);
        const lm_name = std.fmt.allocPrint(alloc, "v{d}_lm", .{phi.words[2]}) catch "vlm";
        if (names.fetchPut(phi.words[2], lm_name) catch null) |old| alloc.free(old.value);
        try w.print("    {s} {s};\n", .{ t, lm_name });
        if (g_materialized_phis) |mp| mp.put(phi.words[2], {}) catch {};
    }

    // #early-return-in-loop: expose this loop's merge + phis to emitBlock so a
    // non-trivial break block (e.g. a return point that stores then branches to
    // the loop merge) can emit the loop-merge-phi copy + `break;`. Saved/restored
    // for nesting.
    const saved_lmc = g_loop_merge_ctx;
    g_loop_merge_ctx = .{ .merge_label = merge_lbl, .phis = loop_mphis.items, .continue_label = cont_lbl, .latch_phis = latch_mphis.items };

    // #loop-break-out-of-switch: arm the flag when this loop sits inside a switch
    // case AND something in its region branches straight to the switch's merge
    // (the multi-level break). do-while paths already honest-error on such
    // branches (their flat body scan rejects any OpBranch off the loop), so they
    // never arm. The post-loop guard is emitted at the loop close below.
    var swbrk: ?[]const u8 = null;
    const saved_swbrk = g_swbrk_flag;
    if (!is_do_while) {
        if (g_switch_ctx) |sctx| {
            const swm_idx = label_map.get(merge_lbl) orelse m.instructions.len;
            if (loopRegionBreaksToSwitchMSL(m, loop_idx, swm_idx, sctx.merge_label)) {
                swbrk = std.fmt.allocPrint(alloc, "_swbrk_{d}", .{loop_idx}) catch "_swbrk";
                try w.print("    bool {s} = false;\n", .{swbrk.?});
                g_swbrk_flag = swbrk;
            }
        }
    }

    if (dw_native) {
        try w.writeAll("    do\n    {\n");
    } else {
        try w.writeAll("    while (true)\n    {\n");
    }

    // #496: Pre-declare selection-merge phi vars inside this loop. A loop-carried phi
    // set in an if/else is read in the continue block (next iteration), but #474 declares
    // it at the if/else merge (inside the body) -- too late. Scan the loop body for OpPhi
    // (skip loop-header phis) + declare + rename here, before the continue block.
    {
        const mend = if (label_map.get(merge_lbl)) |mi| mi else m.instructions.len;
        var si: usize = loop_idx + 2;
        while (si < mend and si < m.instructions.len) : (si += 1) {
            const sinst = m.instructions[si];
            if (sinst.op != .Phi or sinst.words.len < 4) continue;
            const phi_result = sinst.words[2];
            if (g_phi_hdr) |ph| if (ph.get(phi_result) != null) continue;
            // #77: the do-while back-edge CONDITION phi (a short-circuit && / || cond)
            // is rebuilt inline as a ternary by tryInlineDoWhileCond — it is NOT a
            // loop-carried var, so don't pre-declare/rename it (would emit a stray
            // unused `bool vN_phi;` and shadow the inline reconstruction).
            if (is_do_while and phi_result == bc.words[1]) continue;
            // #413 already hoisted this phi's declaration above the loop (it's a
            // loop-carried phi's back-edge value defined inside the body). Don't
            // redeclare/rename it inside — #474's if/else materialization honors the
            // hoist (uses this hoisted name), and the carry reads it. Redeclaring
            // inside would shadow it with a per-iteration-uninitialized var
            // (switch_in_loop, maxdiff 255).
            if (g_hoisted_ids) |h| if (h.contains(phi_result)) continue;
            _ = names.get(phi_result) orelse continue;
            const t = mslValueType(m, sinst.words[1], names, alloc) catch continue;
            const pn = mslPhiVarName(names, phi_result, alloc);
            if (mslPhiDeclare(phi_result)) try w.print("    {s} {s};\n", .{ t, pn });
            _ = names.fetchPut(phi_result, pn) catch {};
            if (g_materialized_phis) |mp| mp.put(phi_result, {}) catch {};
        }
    }

    if (!is_do_while) {
        try w.print("        if (!{s})\n        {{\n", .{first_flag});
        const cont_idx0 = label_map.get(cont_lbl) orelse m.instructions.len;
        if (cont_idx0 < m.instructions.len) {
            var ci0: usize = cont_idx0 + 1;
            while (ci0 < m.instructions.len) : (ci0 += 1) {
                const cinst = m.instructions[ci0];
                if (cinst.op == .FunctionEnd or cinst.op == .Label or cinst.op == .Branch) break;
                if (cinst.op == .LoopMerge) continue;
                if (cinst.op == .SelectionMerge) {
                    // #loop-continue-deadincr: a SelectionMerge in the continue/latch
                    // block is a CONDITIONAL increment (a guarded store in an
                    // intermediate block this linear scan cannot reach). For !has_phis
                    // loops (newly using this top path) honest-error rather than silently
                    // drop the guarded store -> a wrong counter (mirrors the bottom
                    // walker's guard). has_phis loops keep their existing skip behavior.
                    if (!has_phis) return error.UnstructuredControlFlow;
                    continue;
                }
                try emitInstruction(m, names, decs, cinst, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
            }
        }
        if (g_loop_phis) |lp| {
            if (lp.get(loop_idx)) |plist| {
                // #loop-carry-ordering: emit the carry copies in DEPENDENCY ORDER. A
                // phi whose update value is another carry phi's result (parallel
                // assignment, e.g. `c=a+b; a=b; b=c`) must be assigned FIRST, while
                // the source still holds the OLD value — else `a=b` reads the already-
                // updated `b` and the loop computes wrong (fibonacci_mod, maxdiff 179).
                // Topo rule: pair i before j when vname[i]==rname[j] (i reads j's
                // result, so i must run before j overwrites it).
                var rbuf: [16][]const u8 = undefined;
                var vbuf: [16][]const u8 = undefined;
                var cn: usize = 0;
                for (plist.items) |pi| {
                    if (cn >= 16) break;
                    const rname = names.get(pi.result_id) orelse continue;
                    const vname = names.get(pi.update_id) orelse continue;
                    if (std.mem.eql(u8, rname, vname)) continue;
                    rbuf[cn] = rname;
                    vbuf[cn] = vname;
                    cn += 1;
                }
                var emitted = [_]bool{false} ** 16;
                var emitted_cnt: usize = 0;
                while (emitted_cnt < cn) {
                    var progressed = false;
                    var idx: usize = 0;
                    while (idx < cn) : (idx += 1) {
                        if (emitted[idx]) continue;
                        // idx is ready when every k with vname[k]==rname[idx] is
                        // already emitted (those read idx's result → must run first).
                        var ready = true;
                        var k: usize = 0;
                        while (k < cn) : (k += 1) {
                            if (k == idx or emitted[k]) continue;
                            if (std.mem.eql(u8, vbuf[k], rbuf[idx])) {
                                ready = false;
                                break;
                            }
                        }
                        if (ready) {
                            try w.print("        {s} = {s};\n", .{ rbuf[idx], vbuf[idx] });
                            emitted[idx] = true;
                            emitted_cnt += 1;
                            progressed = true;
                            break;
                        }
                    }
                    if (!progressed) {
                        // Dependency cycle (shouldn't occur for structured SSA) — emit
                        // the rest in original order as a safe fallback.
                        var j: usize = 0;
                        while (j < cn) : (j += 1) {
                            if (!emitted[j]) {
                                try w.print("        {s} = {s};\n", .{ rbuf[j], vbuf[j] });
                                emitted[j] = true;
                                emitted_cnt += 1;
                            }
                        }
                    }
                }
            }
        }
        try w.writeAll("        }\n");
        try w.print("        {s} = false;\n", .{first_flag});
    }

    var cond_name: []const u8 = names.get(bc.words[1]) orelse "true";

    // #shortcircuit-loop-cond: no separate condition block -- the chain is emitted by
    // the body walk (starting at the chain head) as nested selections, and the exit
    // test is the chain's final branch (handled by the walker's #shortcircuit-exit
    // rule). Neither the Pattern-A cond replay nor the top test applies.
    if (no_top_test) cond_start = null;

    // Emit condition block instructions (Pattern A)
    if (cond_start) |cs| {
        if (cs < cond_end) {
            var ci: usize = cs;
            while (ci < cond_end) : (ci += 1) {
                const cinst = m.instructions[ci];
                if (cinst.op == .Label or cinst.op == .Branch or cinst.op == .SelectionMerge or cinst.op == .LoopMerge) continue;
                try emitInstruction(m, names, decs, cinst, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
            }
        }
    } else if (!no_top_test) {
        // Pattern B: replay the header's non-phi (condition) instructions inside the
        // loop so the comparison re-evaluates against the live loop counter.
        var hlabel: usize = loop_idx;
        while (hlabel > 0) : (hlabel -= 1) {
            if (m.instructions[hlabel].op == .Label) break;
        }
        var hp = hlabel + 1;
        while (hp < loop_idx) : (hp += 1) {
            const hinst = m.instructions[hp];
            if (hinst.op == .Phi or hinst.op == .Label or hinst.op == .SelectionMerge or hinst.op == .LoopMerge or hinst.op == .Branch or hinst.op == .BranchConditional) continue;
            try emitInstruction(m, names, decs, hinst, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
        }
        cond_name = names.get(bc.words[1]) orelse cond_name;
    }

    if (!is_do_while and !no_top_test) {
        // #loop-merge-phi fallback: assign each merge var its NORMAL-EXIT incoming
        // every iteration. This is the value used on a normal exit, AND the safe
        // fallback for any break path not explicitly handled below (a break that
        // does not overwrite the var leaves the normal-exit value — exactly the old
        // alias-to-first-incoming behavior, so no regression on currently-passing
        // loops). Handled break paths overwrite with the correct break incoming.
        for (loop_mphis.items) |phi| {
            try emitMergePhiCopyForPred(m, names, phi, lm_norm_pred, "        ", w, alloc);
        }
        try w.print("        if (!({s})) break;\n", .{cond_name}); // top-test only
    }

    // Emit body block. When spirv-opt -O merges the body INTO the continue block
    // (body_lbl == cont_lbl), the body was already emitted in the if(!first) skip
    // above (the continue block); skip it here to avoid duplicating every
    // iteration's work (maxdiff=255 — completely wrong output). Found via
    // prove_opt.sh (optimized-SPIR-V MSL backend render-diff).
    const body_idx = if (body_lbl == cont_lbl) m.instructions.len else label_map.get(body_lbl) orelse m.instructions.len;
    if (body_idx < m.instructions.len) {
        var bi: usize = body_idx + 1;
        var cur_body_lbl: u32 = body_lbl; // current block label (for direct break-to-merge merge-phi copies)
        while (bi < m.instructions.len) : (bi += 1) {
            const binst = m.instructions[bi];
            if (binst.op == .FunctionEnd) break;
            if (isDeferredHdrMSL(bi)) continue;
            if (try tryEmitLoopPhiDeclMSL(m, names, binst, w, alloc, "        ")) continue;
            if (binst.op == .Label and binst.words.len > 1) {
                const lbl = binst.words[1];
                if (lbl == cont_lbl or lbl == merge_lbl) break;
                cur_body_lbl = lbl;
                continue;
            }
            if (binst.op == .LoopMerge) {
                if (binst.words.len >= 3) {
                    const nmerge = binst.words[1];
                    const ncont = binst.words[2];
                    bi = try emitWhileLoopMSL(m, names, decs, bi, nmerge, ncont, label_map, bc_merge, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
                    bi -= 1;
                }
                continue;
            }
            if (binst.op == .SelectionMerge) continue;
            // #478: a switch inside a loop body — emit it (was silently dropped).
            if (binst.op == .Switch and binst.words.len >= 3) {
                const sn = names.get(binst.words[1]) orelse "s";
                const dl = binst.words[2];
                const smerge = bc_merge.get(bi);
                if (smerge) |sml| {
                    var sphis: std.ArrayList(Instruction) = .empty;
                    defer sphis.deinit(alloc);
                    collectSwitchMergePhis(m, label_map, sml, &sphis, alloc);
                    finalizeSwitchPhis(names, sphis.items, alloc);
                    try emitSwitchPhiDecls(m, names, sphis.items, w, alloc);
                    const saved_switch_ctx = g_switch_ctx;
                    g_switch_ctx = .{ .merge_label = sml, .phis = sphis.items };
                    try w.print("        switch ({s}) {{\n", .{sn});
                    if (dl != sml) {
                        try w.writeAll("        default: {\n");
                        _ = try emitBlock(m, names, decs, dl, sml, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                        try emitSwitchPhiCaseCopy(m, names, sphis.items, dl, w, alloc);
                        try w.writeAll("        break;\n        }\n");
                    }
                    var swi: usize = 3;
                    while (swi + 1 < binst.words.len) : (swi += 2) {
                        const cv = binst.words[swi];
                        const target = binst.words[swi + 1];
                        if (target == sml) continue;
                        try w.print("        case {d}: {{\n", .{switchCaseLiteral(m, binst.words[1], cv)});
                        _ = try emitBlock(m, names, decs, target, sml, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                        try emitSwitchPhiCaseCopy(m, names, sphis.items, target, w, alloc);
                        try w.writeAll("        break;\n        }\n");
                    }
                    try w.writeAll("        }\n");
                    g_switch_ctx = saved_switch_ctx;
                    if (label_map.get(sml)) |smi| bi = smi;
                }
                continue;
            }
            if (binst.op == .Branch) {
                // #loopcond-not-exit: on a no-top-test loop, a walker-level OpBranch to
                // the loop merge is the loop exit -- emit the break (the arm-walker form
                // is handled by emitBlock's #early-return-in-loop). The old silent skip
                // left the loop exit-less.
                if (no_top_test and binst.words.len > 1 and binst.words[1] == merge_lbl) {
                    try w.writeAll("        break;\n");
                    continue;
                }
                // #continue/latch fall-through: an unconditional OpBranch to the
                // latch is the body's natural end — assign the latch phi(s) for this
                // fall-through predecessor (blockLabelOf resolves it; cur_body_lbl is
                // stale here, same Label-skip staleness as emitBlock).
                if (binst.words.len > 1 and binst.words[1] == cont_lbl and latch_mphis.items.len > 0) {
                    const fp = blockLabelOf(m, bi);
                    for (latch_mphis.items) |phi| try emitMergePhiCopyForPred(m, names, phi, fp, "        ", w, alloc);
                }
                // #loop-break-out-of-switch: a direct OpBranch to the enclosing
                // switch's merge from the loop body's top level (the walker's old
                // generic skip DROPPED it and kept walking into the merge block
                // inline). Copy the switch-merge phi(s) for this predecessor, set
                // the flag, `break;` the loop -- the post-loop guard exits the
                // switch. (Invalid structured input; see g_swbrk_flag.)
                if (g_switch_ctx) |sctx| if (binst.words.len > 1 and sctx.merge_label == binst.words[1]) {
                    for (sctx.phis) |phi| try emitMergePhiCopyForPred(m, names, phi, blockLabelOf(m, bi), "        ", w, alloc);
                    if (g_swbrk_flag) |f| try w.print("        {s} = true;\n", .{f});
                    try w.writeAll("        break;\n");
                    break;
                };
                if (binst.words.len > 1 and (binst.words[1] == cont_lbl or binst.words[1] == merge_lbl)) continue;
                continue;
            }
            if (binst.op == .BranchConditional) {
                const ncn = names.get(binst.words[1]) orelse "c";
                const ntl = binst.words[2];
                const nfl = if (binst.words.len > 3) binst.words[3] else null;
                const nml = bc_merge.get(bi);
                // #loop-break-out-of-switch: a BranchConditional arm DIRECTLY
                // targeting the enclosing switch's merge (a multi-level break).
                // Neither the trivial-break fast paths below (they compare the
                // LOOP's merge) nor the general arm walk (it re-emits the switch's
                // merge block inline, without this pred's phi copy) handles it.
                // Lower as a guarded break: the phi copy for this block, the flag
                // set, `break;` the loop -- the post-loop guard exits the switch --
                // then walk the other arm. (Invalid structured input; see
                // g_swbrk_flag -- a valid module cannot reach this branch.)
                if (g_switch_ctx) |sctx| if (ntl == sctx.merge_label or (nfl != null and nfl.? == sctx.merge_label)) {
                    const pred = blockLabelOf(m, bi);
                    if (ntl == sctx.merge_label) {
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        try emitSwitchMergeBreakMSL(m, names, sctx, pred, "            ", w, alloc);
                        try w.writeAll("        }\n");
                        if (nfl != null and nfl.? != sctx.merge_label) {
                            if (nml) |om| if (om != nfl.?) {
                                _ = try emitBlock(m, names, decs, nfl.?, om, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                                if (label_map.get(om)) |omi| bi = omi;
                            };
                        }
                    } else {
                        const walked_else = blk: {
                            if (nml) |om| {
                                if (om != ntl) {
                                    try w.print("        if ({s})\n        {{\n", .{ncn});
                                    _ = try emitBlock(m, names, decs, ntl, om, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                                    try w.writeAll("        } else {\n");
                                    try emitSwitchMergeBreakMSL(m, names, sctx, pred, "            ", w, alloc);
                                    try w.writeAll("        }\n");
                                    if (label_map.get(om)) |omi| bi = omi;
                                    break :blk true;
                                }
                            }
                            break :blk false;
                        };
                        if (!walked_else) {
                            // true arm IS the selection merge (or no merge info):
                            // guard only the break and keep walking linearly.
                            try w.print("        if (!({s}))\n        {{\n", .{ncn});
                            try emitSwitchMergeBreakMSL(m, names, sctx, pred, "            ", w, alloc);
                            try w.writeAll("        }\n");
                        }
                    }
                    continue;
                };
                // #shortcircuit-exit: on a NO-TOP-TEST loop (a short-circuit condition
                // chain lowered structurally, #shortcircuit-loop-cond), the chain's FINAL
                // BranchConditional -- the one whose target IS the loop merge -- is the
                // loop's real exit test. cfg_structurize synthesizes a SelectionMerge
                // keyed to the LOOP merge above it (or it has none), so it masquerades as
                // a body selection whose merge is the loop merge; the ordinary arms would
                // emit its non-merge target as an unguarded arm and the loop would have
                // NO exit at all. Emit the breaking path's loop-merge-phi copies (this
                // block is the normal-exit predecessor) + the guarded break, then keep
                // walking into the non-breaking target (the loop body follows linearly).
                // Gated on no_top_test so ordinary loops' BC handling is untouched.
                if (no_top_test and (nml == null or nml.? == merge_lbl) and
                    (ntl == merge_lbl or (nfl != null and nfl.? == merge_lbl)))
                {
                    const break_when_true = ntl == merge_lbl;
                    if (loop_mphis.items.len > 0) {
                        const bp = blockLabelOf(m, bi);
                        for (loop_mphis.items) |phi| try emitMergePhiCopyForPred(m, names, phi, bp, "        ", w, alloc);
                    }
                    if (break_when_true) {
                        try w.print("        if ({s}) break;\n", .{ncn});
                    } else {
                        try w.print("        if (!({s})) break;\n", .{ncn});
                    }
                    continue;
                }
                const tl_is_trivial_continue = blk: {
                    if (ntl == cont_lbl) break :blk true;
                    const tli = label_map.get(ntl) orelse break :blk false;
                    if (tli + 2 < m.instructions.len and m.instructions[tli].op == .Label and m.instructions[tli + 1].op == .Branch and m.instructions[tli + 1].words.len > 1 and m.instructions[tli + 1].words[1] == cont_lbl) break :blk true;
                    break :blk false;
                };
                const fl_is_trivial_continue = blk: {
                    if (nfl == null) break :blk false;
                    if (nfl.? == cont_lbl) break :blk true;
                    const fli = label_map.get(nfl.?) orelse break :blk false;
                    if (fli + 2 < m.instructions.len and m.instructions[fli].op == .Label and m.instructions[fli + 1].op == .Branch and m.instructions[fli + 1].words.len > 1 and m.instructions[fli + 1].words[1] == cont_lbl) break :blk true;
                    break :blk false;
                };
                const tl_is_trivial_break = blk: {
                    if (ntl == merge_lbl) break :blk true;
                    const tli2 = label_map.get(ntl) orelse break :blk false;
                    if (tli2 + 2 < m.instructions.len and m.instructions[tli2].op == .Label and m.instructions[tli2 + 1].op == .Branch and m.instructions[tli2 + 1].words.len > 1 and m.instructions[tli2 + 1].words[1] == merge_lbl) break :blk true;
                    break :blk false;
                };
                const fl_is_trivial_break = blk: {
                    if (nfl == null) break :blk false;
                    if (nfl.? == merge_lbl) break :blk true;
                    const fli2 = label_map.get(nfl.?) orelse break :blk false;
                    if (fli2 + 2 < m.instructions.len and m.instructions[fli2].op == .Label and m.instructions[fli2 + 1].op == .Branch and m.instructions[fli2 + 1].words.len > 1 and m.instructions[fli2 + 1].words[1] == merge_lbl) break :blk true;
                    break :blk false;
                };
                if (nml) |nmv| {
                    const nhe = nfl != null and nfl.? != nmv;
                    // #latch-phi: resolve each copy's predecessor with blockLabelOf(m, bi)
                    // (this BranchConditional's own block), not cur_body_lbl - the walker
                    // jumps over block Labels after a nested switch/loop (bi = merge idx +
                    // loop increment), so a tracked "current label" can be stale here, same
                    // Label-skip staleness the branch-to-continue fall-through below
                    // documents. A stale pred matches no phi incoming -> NO copy emitted
                    // -> the loop-header carry read a stale carrier (silent-wrong).
                    if (tl_is_trivial_continue and (fl_is_trivial_break or !nhe)) {
                        if (latch_mphis.items.len > 0) {
                            const cp = if (ntl == cont_lbl) blockLabelOf(m, bi) else ntl;
                            for (latch_mphis.items) |phi| try emitMergePhiCopyForPred(m, names, phi, cp, "        ", w, alloc);
                        }
                        try w.print("        if ({s}) continue;\n", .{ncn});
                    } else if (tl_is_trivial_break and fl_is_trivial_continue) {
                        if (loop_mphis.items.len > 0) {
                            const bp = if (ntl == merge_lbl) cur_body_lbl else ntl;
                            for (loop_mphis.items) |phi| try emitMergePhiCopyForPred(m, names, phi, bp, "        ", w, alloc);
                        }
                        try w.print("        if ({s}) break;\n", .{ncn});
                        // #latch-phi: the `continue;` below is unconditional on the
                        // non-break path - the FALSE arm's latch copy must precede it
                        // (this fast path previously emitted none; the copy above the
                        // break only covers the loop-MERGE phis, a different mechanism).
                        // The copy also runs on the break path, harmlessly: a break path
                        // never reads the latch carrier again (HLSL #619 placement).
                        if (latch_mphis.items.len > 0) {
                            const cp = if (nfl.? == cont_lbl) blockLabelOf(m, bi) else nfl.?;
                            for (latch_mphis.items) |phi| try emitMergePhiCopyForPred(m, names, phi, cp, "        ", w, alloc);
                        }
                        try w.writeAll("        continue;\n");
                    } else if (tl_is_trivial_continue and nhe) {
                        if (latch_mphis.items.len > 0) {
                            const cp = if (ntl == cont_lbl) blockLabelOf(m, bi) else ntl;
                            for (latch_mphis.items) |phi| try emitMergePhiCopyForPred(m, names, phi, cp, "        ", w, alloc);
                        }
                        try w.print("        if ({s}) continue;\n", .{ncn});
                        bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                    } else if (tl_is_trivial_break) {
                        if (loop_mphis.items.len > 0) {
                            const bp = if (ntl == merge_lbl) cur_body_lbl else ntl;
                            for (loop_mphis.items) |phi| try emitMergePhiCopyForPred(m, names, phi, bp, "        ", w, alloc);
                        }
                        try w.print("        if ({s}) break;\n", .{ncn});
                        if (nhe) {
                            bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                        }
                    } else if (fl_is_trivial_continue) {
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        // #latch-phi: capture this branch's block BEFORE emitBlock
                        // reassigns bi (blockLabelOf of the post-jump index could land
                        // inside the emitted arm).
                        const bc_lbl = blockLabelOf(m, bi);
                        bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                        // #latch-phi: the `} continue;` below is unconditional on the
                        // non-true path - the FALSE arm's latch copy must precede it.
                        // On the true arm's own continue path a copy INSIDE the arm
                        // (emitBlock's branch-to-continue) precedes this one, so the last
                        // write before any `continue;` is the correct one; a merge/return
                        // path never reads the carrier again (HLSL #619 placement).
                        if (latch_mphis.items.len > 0) {
                            const cp = if (nfl.? == cont_lbl) bc_lbl else nfl.?;
                            for (latch_mphis.items) |phi| try emitMergePhiCopyForPred(m, names, phi, cp, "        ", w, alloc);
                        }
                        try w.writeAll("        } continue;\n");
                    } else if (fl_is_trivial_break and !nhe) {
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                        try w.writeAll("        }\n");
                    } else {
                        // #474: materialize selection-merge phis of a loop-body if/else
                        // (mirrors emitBody/emitBlock). Without this, a value that differs
                        // by branch (`v = cond ? a : b` kept as a real if/else, e.g.
                        // conditional texture samples) aliases to its FIRST incoming
                        // operand -> the else branch's value is silently dropped and the
                        // true-branch temp is referenced out of scope in the else path.
                        var mphis: std.ArrayList(MslMergePhi) = .empty;
                        defer mphis.deinit(alloc);
                        collectMergePhis(m, label_map, nmv, &mphis, alloc);
                        // Declaration: skip phis already pre-declared by the loop pre-scan (#496).
                        for (mphis.items) |pv| {
                            const vn = mslPhiVarName(names, pv.result_id, alloc);
                            // `or` short-circuits, so mslPhiDeclare is consulted (and marks)
                            // only where the pre-#496 condition would have declared. It can
                            // then still divert to the assignment form if an enclosing
                            // construct already emitted the declaration.
                            const pre_decl = (if (g_materialized_phis) |mp| mp.contains(pv.result_id) else false) or (if (g_hoisted_ids) |h| h.contains(pv.result_id) else false) or !mslPhiDeclare(pv.result_id);
                            if (pre_decl) {
                                // Pre-declared by the loop pre-scan (#496): skip the
                                // declaration, but for no-else emit the fall-through
                                // init. Without this the phi is uninitialized when the
                                // condition is false → wrong render (maxdiff up to 255).
                                // For has-else, both branches assign (below) — no init.
                                if (!nhe) {
                                    const false_val = if (mslPhiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                                    try w.print("        {s} = {s};\n", .{ vn, mslExprName(m, names, false_val, alloc) });
                                }
                            } else {
                                const t = try mslValueType(m, pv.type_id, names, alloc);
                                if (nhe) {
                                    try w.print("        {s} {s};\n", .{ t, vn });
                                } else {
                                    const false_val = if (mslPhiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                                    try w.print("        {s} {s} = {s};\n", .{ t, vn, mslExprName(m, names, false_val, alloc) });
                                }
                            }
                        }
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                        // Assignments: one name for pre-declared and new phis alike --
                        // mslPhiVarName is derived from the result id, so it matches the
                        // declaration above without depending on which pass ran first.
                        for (mphis.items) |pv| {
                            const phi_name = mslPhiVarName(names, pv.result_id, alloc);
                            const true_val = if (mslPhiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[1] else pv.vals[0];
                            try w.print("            {s} = {s};\n", .{ phi_name, mslExprName(m, names, true_val, alloc) });
                        }
                        if (nhe) {
                            try w.writeAll("        } else {\n");
                            bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", cbuffers, textures, storage_buffers, arraylen_buf_index);
                            for (mphis.items) |pv| {
                                const phi_name = mslPhiVarName(names, pv.result_id, alloc);
                                const false_val = if (mslPhiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                                try w.print("            {s} = {s};\n", .{ phi_name, mslExprName(m, names, false_val, alloc) });
                            }
                        }
                        try w.writeAll("        }\n");
                        // Rename: skip phis already pre-renamed by the loop pre-scan (#496).
                        for (mphis.items) |pv| {
                            if (g_materialized_phis) |mp| if (mp.contains(pv.result_id)) continue;
                            if (g_hoisted_ids) |h| if (h.contains(pv.result_id)) continue; // #413 hoisted above the loop: keep its name, don't rename to _phi
                            const pn = mslPhiVarName(names, pv.result_id, alloc);
                            if (names.fetchPut(pv.result_id, pn) catch null) |old| alloc.free(old.value);
                            if (g_materialized_phis) |mp| mp.put(pv.result_id, {}) catch {};
                        }
                    }
                    if (label_map.get(nmv)) |nmi| {
                        bi = nmi;
                    }
                }
                continue;
            }
            try emitInstruction(m, names, decs, binst, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
        }
    }
    // Emit continue block (e.g., i++ in for-loops) at the BOTTOM. ALL top-test loops
    // (!is_do_while) now hoist the update to the top (#237 / #loop-continue-deadincr),
    // so this bottom walker runs only for straight-line do-while (pattern C:
    // is_do_while && !dw_native). The native do-while (#246) rebuilds its latch
    // condition inline below — not as body statements.
    if (is_do_while and !dw_native) {
        const cont_idx = label_map.get(cont_lbl) orelse m.instructions.len;
        if (cont_idx < m.instructions.len) {
            var ci2: usize = cont_idx + 1;
            while (ci2 < m.instructions.len) : (ci2 += 1) {
                const cinst = m.instructions[ci2];
                if (cinst.op == .FunctionEnd) break;
                if (cinst.op == .Label) break;
                if (cinst.op == .Branch) break;
                if (cinst.op == .BranchConditional) break; // do-while back-edge — handled below
                if (cinst.op == .LoopMerge) continue;
                // A SelectionMerge in a NON-do-while continue/latch block is a CONDITIONAL
                // increment (`for (...; cond ? a : b++)`): the SelectionMerge guards a
                // side-effecting store in an intermediate block. This straight-line walker
                // skips the SelectionMerge and then breaks at the BranchConditional, silently
                // DROPPING the guarded store, so the loop counter never advances (an infinite
                // loop that renders all-black). Honest-error instead of miscompiling. A
                // do-while's latch also carries a SelectionMerge before its back-edge
                // conditional, but there the condition is the loop test (handled by the
                // is_do_while path below) with no dropped intermediate block, so exclude it.
                if (cinst.op == .SelectionMerge) {
                    if (!is_do_while) return error.UnstructuredControlFlow;
                    continue;
                }
                try emitInstruction(m, names, decs, cinst, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
            }
        }
    }
    if (dw_native) {
        // Native do-while (#246): close with the inlined back-edge condition over the
        // persistent loop vars. A body `continue` lands here and re-evaluates correctly.
        const cond = dw_inlined.?;
        if (dw_loop_when_true) {
            try w.print("    }} while ({s});\n", .{cond});
        } else {
            try w.print("    }} while (!({s}));\n", .{cond});
        }
    } else {
        // do-while (pattern C, straight-line body): test the back-edge condition at the
        // BOTTOM of the while(true) loop.
        if (is_do_while) {
            const dwc = names.get(bc.words[1]) orelse "true";
            if (dw_loop_when_true) {
                try w.print("        if (!({s})) break;\n", .{dwc});
            } else {
                try w.print("        if ({s}) break;\n", .{dwc});
            }
        }
        try w.writeAll("    }\n");
    }
    // #loop-break-out-of-switch: the flag's post-loop guard. A set flag means a
    // break-to-switch-merge fired inside the loop: the case's remaining code must
    // be SKIPPED (it would clobber the switch-merge phi copied at the site). With
    // no enclosing armed loop the `break;` exits the switch itself; inside another
    // loop it exits ONE level and propagates the parent flag, whose own post-loop
    // guard carries it the rest of the way out.
    if (swbrk) |f| {
        if (saved_swbrk) |pf| {
            try w.print("    if ({s})\n    {{\n    {s} = true;\n    break;\n    }}\n", .{ f, pf });
        } else {
            try w.print("    if ({s})\n    {{\n    break;\n    }}\n", .{f});
        }
    }
    g_swbrk_flag = saved_swbrk;
    g_loop_merge_ctx = saved_lmc;
    if (label_map.get(merge_lbl)) |mi| return mi;
    return loop_idx + 1;
}

// True iff block `label` is a loop header: it carries an OpLoopMerge before its terminator.
// (A loop header may compute its exit condition between the OpPhi and the OpLoopMerge, so
// scan the whole block, not just the first instruction.) Used by emitBlock to honest-error
// when a branch arm tries to enter a nested loop it cannot emit.
fn blockIsLoopHeader(m: *const ParsedModule, label: u32, lm: *const std.AutoHashMap(u32, usize)) bool {
    const si = lm.get(label) orelse return false;
    var i: usize = si + 1;
    while (i < m.instructions.len) : (i += 1) {
        const op = m.instructions[i].op;
        if (op == .LoopMerge) return true;
        if (op == .Label or op == .Branch or op == .BranchConditional or op == .FunctionEnd) return false;
    }
    return false;
}

fn emitBlock(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    label: u32,
    merge_label: u32,
    lm: *const std.AutoHashMap(u32, usize),
    bm: *const std.AutoHashMap(usize, u32),
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    ovid: ?u32,
    indent: []const u8,
    cbuffers: *const std.ArrayList(CbufferDecl),
    textures: *const std.ArrayList(TextureDecl),
    storage_buffers: *const std.ArrayList(CbufferDecl),
    arraylen_buf_index: *const std.AutoHashMap(u32, u32),
) anyerror!usize { // explicit set breaks the emitBlock<->emitWhileLoopMSL inferred-error cycle
    const si = lm.get(label) orelse return error.InvalidSpirv;
    var i: usize = si + 1;
    while (i < m.instructions.len) : (i += 1) {
        const inst = m.instructions[i];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .Label or inst.op == .SelectionMerge) continue;
        if (inst.op == .Branch and inst.words.len > 1 and inst.words[1] == merge_label) {
            // #multi-return: a branch to the enclosing switch's merge is an early
            // return (spirv-opt lowered it); assign the switch-merge phi(s) for this
            // predecessor first, or the return-value var stays uninitialized.
            if (g_switch_ctx) |ctx| if (ctx.merge_label == merge_label) {
                for (ctx.phis) |phi| try emitMergePhiCopyForPred(m, names, phi, blockLabelOf(m, i), indent, w, alloc);
            };
            break;
        }
        // #478: a switch in a branch arm (if/else) — emit it (was silently dropped).
        if (inst.op == .Switch and inst.words.len >= 3) {
            const sn = names.get(inst.words[1]) orelse "s";
            const dl = inst.words[2];
            const smerge = bm.get(i);
            if (smerge) |sml| {
                var sphis: std.ArrayList(Instruction) = .empty;
                defer sphis.deinit(alloc);
                collectSwitchMergePhis(m, lm, sml, &sphis, alloc);
                finalizeSwitchPhis(names, sphis.items, alloc);
                try emitSwitchPhiDecls(m, names, sphis.items, w, alloc);
                const saved_switch_ctx = g_switch_ctx;
                g_switch_ctx = .{ .merge_label = sml, .phis = sphis.items };
                try w.print("{s}    switch ({s}) {{\n", .{ indent, sn });
                if (dl != sml) {
                    try w.print("{s}    default: {{\n", .{indent});
                    // Buffered so the trailing `break;` can be skipped when the body already
                    // left the switch on its own (#dead-case-break).
                    var nb1: std.ArrayList(u8) = .empty;
                    defer nb1.deinit(alloc);
                    _ = try emitBlock(m, names, decs, dl, sml, lm, bm, compat.listWriter(&nb1, alloc), alloc, is_frag, ovid, indent, cbuffers, textures, storage_buffers, arraylen_buf_index);
                    try emitSwitchPhiCaseCopy(m, names, sphis.items, dl, compat.listWriter(&nb1, alloc), alloc);
                    try w.writeAll(nb1.items);
                    if (!caseBodyTerminates(nb1.items)) try w.print("{s}    break;\n", .{indent});
                    try w.print("{s}    }}\n", .{indent});
                }
                var swi: usize = 3;
                while (swi + 1 < inst.words.len) : (swi += 2) {
                    const cv = inst.words[swi];
                    const target = inst.words[swi + 1];
                    if (target == sml) continue;
                    try w.print("{s}    case {d}: {{\n", .{ indent, switchCaseLiteral(m, inst.words[1], cv) });
                    // Buffered so the trailing `break;` can be skipped when the body already
                    // left the switch on its own (#dead-case-break).
                    var nb0: std.ArrayList(u8) = .empty;
                    defer nb0.deinit(alloc);
                    _ = try emitBlock(m, names, decs, target, sml, lm, bm, compat.listWriter(&nb0, alloc), alloc, is_frag, ovid, indent, cbuffers, textures, storage_buffers, arraylen_buf_index);
                    try emitSwitchPhiCaseCopy(m, names, sphis.items, target, compat.listWriter(&nb0, alloc), alloc);
                    try w.writeAll(nb0.items);
                    if (!caseBodyTerminates(nb0.items)) try w.print("{s}    break;\n", .{indent});
                    try w.print("{s}    }}\n", .{indent});
                }
                try w.print("{s}    }}\n", .{indent});
                g_switch_ctx = saved_switch_ctx;
                if (lm.get(sml)) |smi| i = smi;
            }
            continue;
        }
        // A loop nested in this branch arm: delegate to emitWhileLoopMSL (the emitter
        // emitBody uses; it recurses through nested loops/branches). Reached bare (arm IS
        // the header) or via an OpBranch into a separate loop-header block. The header's
        // phi-counter decls must be replayed first (emitBody/loop-scan do it inline; we
        // jump over the header). emitWhileLoopMSL returns the merge-label index.
        if (inst.op == .LoopMerge) {
            if (inst.words.len >= 3) {
                i = try emitWhileLoopMSL(m, names, decs, i, inst.words[1], inst.words[2], lm, bm, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
                i -= 1;
            }
            continue;
        }
        if (inst.op == .Branch) {
            if (inst.words.len > 1 and blockIsLoopHeader(m, inst.words[1], lm)) {
                const hdr_idx = lm.get(inst.words[1]) orelse return error.InvalidSpirv;
                var li: usize = hdr_idx + 1;
                while (li < m.instructions.len and m.instructions[li].op != .LoopMerge) : (li += 1) {
                    _ = tryEmitLoopPhiDeclMSL(m, names, m.instructions[li], w, alloc, indent) catch {};
                }
                if (li >= m.instructions.len or m.instructions[li].words.len < 3) return error.InvalidSpirv;
                i = try emitWhileLoopMSL(m, names, decs, li, m.instructions[li].words[1], m.instructions[li].words[2], lm, bm, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
                i -= 1;
                continue;
            }
            // #early-return-in-loop: a branch to the enclosing LOOP merge is a
            // non-trivial break (e.g. a return point that stored then branches to the
            // loop merge) — assign the loop-merge-phi copy for this predecessor, then
            // `break;` out of the while loop. The post-loop `if(flag) ...` handles the
            // rest. (Checked before the switch-merge case; a block branches to one.)
            if (inst.words.len > 1) {
                if (g_loop_merge_ctx) |ctx| if (ctx.merge_label == inst.words[1]) {
                    for (ctx.phis) |phi| try emitMergePhiCopyForPred(m, names, phi, blockLabelOf(m, i), indent, w, alloc);
                    try w.print("{s}    break;\n", .{indent});
                };
            }
            // #switch-case-continue (MSL): a branch to the enclosing LOOP's continue
            // is a structured continue (e.g. `if (c) continue;` inside a switch case or
            // if-body). Without this emitBlock drops the OpBranch (the branch body is
            // empty) and the continue never fires -> silent-wrong. Mirrors GLSL #584 and
            // the WGSL/HLSL backends (which already track the continue label). The `break`
            // (matching GLSL #584) exits the emitBlock loop; redundant with the centralized
            // break below today, but defensive.
            // #latch-phi (closes the former TODO(latch-phi) from #586; port of GLSL's
            // fix/glsl-latch-phi #613 and HLSL's #619): this continue also carries this
            // block's latch-phi copies - the continue block's divergent leading phis
            // select the back-edge value per predecessor, and without the copy the
            // loop-header carry read an uninitialized/stale carrier on this path
            // (silent-wrong; latch_phi_switch_continue.spv: both case arms continued
            // with v57_phi never written). A degenerate latch phi (all incomings equal)
            // is skipped by collectLoopMergePhis, same as the walker's latch_mphis.
            if (inst.words.len > 1) {
                if (g_loop_merge_ctx) |ctx| if (ctx.continue_label == inst.words[1]) {
                    for (ctx.latch_phis) |phi| try emitMergePhiCopyForPred(m, names, phi, blockLabelOf(m, i), indent, w, alloc);
                    try w.print("{s}    continue;\n", .{indent});
                    break;
                };
            }
            // #multi-return: branch to the enclosing switch merge past this block's
            // immediate merge (early return) — assign the switch-merge phi(s) and
            // `break;` out of the switch case so the lowered if-chain is EXCLUSIVE
            // (each early return exits; without the break the sequential ifs all fire
            // and overwrite the return value -> wrong render, early_return_func).
            if (inst.words.len > 1) {
                if (g_switch_ctx) |ctx| if (ctx.merge_label == inst.words[1]) {
                    for (ctx.phis) |phi| try emitMergePhiCopyForPred(m, names, phi, blockLabelOf(m, i), indent, w, alloc);
                    // #loop-break-out-of-switch: inside an armed loop the bare
                    // `break;` only exits the LOOP -- set the flag so the post-loop
                    // guard skips the rest of the case (which would clobber the phi
                    // copied just above) and exits the switch.
                    if (g_swbrk_flag) |f| try w.print("{s}    {s} = true;\n", .{ indent, f });
                    try w.print("{s}    break;\n", .{indent});
                };
            }
            // #switch-fallthrough: branch to another case-target (fallthrough) —
            // assign the destination's cross-case chain phi(s) for this pred.
            if (inst.words.len > 1) {
                if (g_switch_chain) |chain| {
                    const pred = blockLabelOf(m, i);
                    for (chain) |ce| {
                        if (ce.block == inst.words[1]) {
                            try emitMergePhiCopyForPred(m, names, ce.phi, pred, indent, w, alloc);
                        }
                    }
                }
            }
            break;
        }
        if (inst.op == .BranchConditional) {
            if (inst.words.len < 4) continue;
            const cn = names.get(inst.words[1]) orelse "c";
            const tl = inst.words[2];
            const fl = if (inst.words.len > 3) inst.words[3] else null;
            const nm = bm.get(i);
            if (nm) |nmv| {
                const he = fl != null and fl.? != nmv;
                // Materialize selection-merge phis (see the top-level handler in
                // emitBody). Nested selections need the same treatment or a
                // branch-local value is referenced out of scope after the merge.
                var mphis: std.ArrayList(MslMergePhi) = .empty;
                defer mphis.deinit(alloc);
                collectMergePhis(m, lm, nmv, &mphis, alloc);
                for (mphis.items) |pv| {
                    const t = try mslValueType(m, pv.type_id, names, alloc);
                    const vn = mslPhiVarName(names, pv.result_id, alloc);
                    // See the emitBody site: drop the type, keep the initializer, when an
                    // enclosing construct already declared this variable.
                    const ty: []const u8 = if (mslPhiDeclare(pv.result_id)) t else "";
                    const sep: []const u8 = if (ty.len > 0) " " else "";
                    if (he) {
                        if (ty.len > 0) try w.print("{s}    {s} {s};\n", .{ indent, ty, vn });
                    } else {
                        const false_val = if (mslPhiPred1InTrueRegion(m, lm, tl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                        try w.print("{s}    {s}{s}{s} = {s};\n", .{ indent, ty, sep, vn, mslExprName(m, names, false_val, alloc) });
                    }
                }
                try w.print("{s}    if ({s})\n{s}    {{\n", .{ indent, cn, indent });
                // #switch-arm-break (conditional): an arm DIRECTLY targeting the
                // enclosing switch's merge is a conditional break out of the switch.
                // The old path walked the arm, re-emitting the switch's MERGE block
                // inline inside the arm without this predecessor's phi copy -- the
                // merge phi kept whatever the normal path left in it (silent-wrong on
                // a VALID shape: a producer-lowered flag break branches to the switch
                // merge right after a loop, exactly this). The per-arm assignments
                // below are suppressed for a breaking arm (dead after the break).
                const sctx_bc = g_switch_ctx;
                const tl_is_swbreak = if (sctx_bc) |s| tl == s.merge_label else false;
                const fl_is_swbreak = if (sctx_bc) |s| (fl != null and fl.? == s.merge_label) else false;
                if (tl_is_swbreak) {
                    try emitSwitchMergeBreakMSL(m, names, sctx_bc.?, blockLabelOf(m, i), indent, w, alloc);
                } else {
                    i = try emitBlock(m, names, decs, tl, nmv, lm, bm, w, alloc, is_frag, ovid, indent, cbuffers, textures, storage_buffers, arraylen_buf_index);
                    for (mphis.items) |pv| {
                        const vn = mslPhiVarName(names, pv.result_id, alloc);
                        const true_val = if (mslPhiPred1InTrueRegion(m, lm, tl, nmv, pv.preds[1], alloc)) pv.vals[1] else pv.vals[0];
                        try w.print("{s}        {s} = {s};\n", .{ indent, vn, mslExprName(m, names, true_val, alloc) });
                    }
                }
                if (he) {
                    try w.print("{s}    }} else {{\n", .{indent});
                    if (fl_is_swbreak) {
                        try emitSwitchMergeBreakMSL(m, names, sctx_bc.?, blockLabelOf(m, i), indent, w, alloc);
                    } else {
                        i = try emitBlock(m, names, decs, fl.?, nmv, lm, bm, w, alloc, is_frag, ovid, indent, cbuffers, textures, storage_buffers, arraylen_buf_index);
                        for (mphis.items) |pv| {
                            const vn = mslPhiVarName(names, pv.result_id, alloc);
                            const false_val = if (mslPhiPred1InTrueRegion(m, lm, tl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                            try w.print("{s}        {s} = {s};\n", .{ indent, vn, mslExprName(m, names, false_val, alloc) });
                        }
                    }
                }
                try w.print("{s}    }}\n", .{indent});
                for (mphis.items) |pv| {
                    const pn = mslPhiVarName(names, pv.result_id, alloc);
                    if (names.fetchPut(pv.result_id, pn) catch null) |old| alloc.free(old.value);
                    if (g_materialized_phis) |mp| mp.put(pv.result_id, {}) catch {};
                }
                if (lm.get(nmv)) |nmi| {
                    i = nmi;
                }
            } else {
                try w.print("{s}    if ({s}) {{ /* */ }}\n", .{ indent, cn });
            }
            continue;
        }
        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);

        // #early-return-arm: a return/discard TERMINATES this block, exactly as a Branch
        // to the merge does above. Without it the walker carried on into the selection's
        // MERGE block and emitted the whole continuation of the function inside the arm,
        // after the return -- and then again at the correct scope once the arm closed.
        // The duplicate is unreachable, so every path still returned the right value and
        // no render diff could see it, but the copies nest: each early return in a chain
        // duplicates everything below it, so `if/if/return` chains blow up the output.
        // GLSL closes the arm here and is the reference. 54 corpus shaders were affected.
        switch (inst.op) {
            .Return, .ReturnValue, .Kill, .Unreachable => break,
            else => {},
        }
    }
    return i;
}

// ---- Instruction emission (MSL dialect) ----
// Most instructions are identical to GLSL; key differences:
// - Types: float4/float3/float2 instead of vec4/vec3/vec2
// - Texture: tex.sample(samp, uv) instead of texture(tex, uv)
// - Uniforms: Globals_1._m0 instead of Globals_m0
// - powr instead of pow (GLSL pow is undefined for x<0, matching powr's domain).
//   clamp (all of F/S/UClamp) lowers to plain `clamp` — never `fast::clamp`, which is
//   float-only fast-math and would be wrong/lossy for the integer forms.

/// #170: emit a NaN-correct UNORDERED float inequality as `!(complementary ordered op)`.
/// Metal relational operators are ORDERED (false when either operand is NaN), so mapping
/// OpFUnordLessThan and friends onto `<`/`>=` (as spirv-cross does) is plausible-but-wrong
/// on a NaN operand -- the unordered form must be TRUE there, and `!ordered-complement` is
/// exact by the IEEE-754 / SPIR-V definition. Metal `!` is componentwise on bool vectors,
/// so this is uniform for scalar and vector. Deliberate divergence from spirv-cross.
fn emitNegatedCompare(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, complement_op: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rt = try mslType(m, inst.words[1], names, alloc);
    try w.print("    {s} {s} = !({s} {s} {s});\n", .{
        rt,                                  names.get(inst.words[2]) orelse "v",
        names.get(inst.words[3]) orelse "a", complement_op,
        names.get(inst.words[4]) orelse "b",
    });
}

/// #170 OpFUnordEqual: unordered-equal is TRUE if either operand is NaN (ordered
/// `==` is false there = plausible-but-wrong). Metal's isunordered(a, b) is exactly
/// "either operand is NaN" and is componentwise for vectors, so this single form
/// covers scalar and vector. (spirv-cross MSL lowers the same way.)
fn emitUnordEqual(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator) !void {
    const rt = try mslType(m, inst.words[1], names, alloc);
    try w.print("    {s} {s} = isunordered({s}, {s}) || ({s} == {s});\n", .{
        rt,                                  names.get(inst.words[2]) orelse "v",
        names.get(inst.words[3]) orelse "a", names.get(inst.words[4]) orelse "b",
        names.get(inst.words[3]) orelse "a", names.get(inst.words[4]) orelse "b",
    });
}

/// #170 OpFOrdNotEqual: ordered not-equal is FALSE on a NaN operand, but Metal's `!=`
/// is unordered (true on NaN), so mapping FOrdNotEqual to bare `!=` is plausible-but-
/// wrong. Lower to `!isunordered(a, b) && (a != b)` (ordered-AND-not-equal), exact for
/// scalar and vector. The mirror of emitUnordEqual; glslang never emits FOrdNotEqual.
fn emitOrdNotEqual(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator) !void {
    const rt = try mslType(m, inst.words[1], names, alloc);
    try w.print("    {s} {s} = !isunordered({s}, {s}) && ({s} != {s});\n", .{
        rt,                                  names.get(inst.words[2]) orelse "v",
        names.get(inst.words[3]) orelse "a", names.get(inst.words[4]) orelse "b",
        names.get(inst.words[3]) orelse "a", names.get(inst.words[4]) orelse "b",
    });
}

/// Lower a subgroup ARITHMETIC op (IAdd/FAdd/IMul/FMul/Min/Max/Bitwise/Logical)
/// honoring the GroupOperation literal. SPIR-V layout for these ops:
///   words[1]=ResultType words[2]=Result words[3]=Execution(Scope <id>)
///   words[4]=GroupOperation literal (0=Reduce, 1=InclusiveScan,
///            2=ExclusiveScan, 3=ClusteredReduce)
///   words[5]=Value <id>  words[6]=ClusterSize <id> (ClusteredReduce only)
/// The old code read words[4] as the value; it is the GroupOperation literal, so
/// the value silently fell back to "x" AND every variant lowered as Reduce.
/// Metal has simd_{sum,product,min,max,and,or,xor} for Reduce, and prefix-inclusive
/// /exclusive ONLY for sum/product; Min/Max/And/Or/Xor scans and ALL ClusteredReduce
/// honest-error (no Metal equivalent). (#subgroup-operand)
fn mslEmitSubgroupArith(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    inst: Instruction,
    w: anytype,
    alloc: std.mem.Allocator,
) !void {
    if (inst.words.len < 6) return error.UnsupportedOp;
    const rtt = try mslType(m, inst.words[1], names, alloc);
    const rn = names.get(inst.words[2]) orelse "v";
    const gop = inst.words[4];
    const val = names.get(inst.words[5]) orelse "x";
    const Stem = enum { sum, product, min, max, band, bor, bxor, land, lor };
    const stem: Stem = switch (inst.op) {
        .GroupNonUniformIAdd, .GroupNonUniformFAdd => .sum,
        .GroupNonUniformIMul, .GroupNonUniformFMul => .product,
        .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin => .min,
        .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax => .max,
        .GroupNonUniformBitwiseAnd => .band,
        .GroupNonUniformBitwiseOr => .bor,
        .GroupNonUniformBitwiseXor => .bxor,
        .GroupNonUniformLogicalAnd => .land,
        .GroupNonUniformLogicalOr => .lor,
        else => return error.UnsupportedOp,
    };
    switch (gop) {
        0 => { // Reduce
            switch (stem) {
                .sum => try w.print("    {s} {s} = simd_sum({s});\n", .{ rtt, rn, val }),
                .product => try w.print("    {s} {s} = simd_product({s});\n", .{ rtt, rn, val }),
                .min => try w.print("    {s} {s} = simd_min({s});\n", .{ rtt, rn, val }),
                .max => try w.print("    {s} {s} = simd_max({s});\n", .{ rtt, rn, val }),
                .band => try w.print("    {s} {s} = simd_and({s});\n", .{ rtt, rn, val }),
                .bor => try w.print("    {s} {s} = simd_or({s});\n", .{ rtt, rn, val }),
                .bxor => try w.print("    {s} {s} = simd_xor({s});\n", .{ rtt, rn, val }),
                .land => try w.print("    {s} {s} = simd_all({s}) ? true : false;\n", .{ rtt, rn, val }),
                .lor => try w.print("    {s} {s} = simd_any({s}) ? true : false;\n", .{ rtt, rn, val }),
            }
        },
        1 => { // InclusiveScan: Metal prefix-inclusive only for sum/product
            switch (stem) {
                .sum => try w.print("    {s} {s} = simd_prefix_inclusive_sum({s});\n", .{ rtt, rn, val }),
                .product => try w.print("    {s} {s} = simd_prefix_inclusive_product({s});\n", .{ rtt, rn, val }),
                else => return error.UnsupportedOp,
            }
        },
        2 => { // ExclusiveScan: Metal prefix-exclusive only for sum/product
            switch (stem) {
                .sum => try w.print("    {s} {s} = simd_prefix_exclusive_sum({s});\n", .{ rtt, rn, val }),
                .product => try w.print("    {s} {s} = simd_prefix_exclusive_product({s});\n", .{ rtt, rn, val }),
                else => return error.UnsupportedOp,
            }
        },
        3 => return error.UnsupportedOp, // ClusteredReduce: no Metal equivalent
        else => return error.UnsupportedOp,
    }
}

fn emitInstruction(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    inst: Instruction,
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    ovid: ?u32,
    cbuffers: *const std.ArrayList(CbufferDecl),
    textures: *const std.ArrayList(TextureDecl),
    storage_buffers: *const std.ArrayList(CbufferDecl),
    arraylen_buf_index: *const std.AutoHashMap(u32, u32),
) !void {
    // #413: this instruction defines a loop-carried phi update temp whose
    // declaration was hoisted above the loop — re-render it with the type
    // stripped so it assigns the hoisted variable instead of redeclaring it
    // in an inner scope.
    if (!g_hoist_stripping) {
        if (g_hoisted_ids) |h| {
            if (resultIdFromOp(inst.op, inst.words)) |rid| {
                if (h.contains(rid)) {
                    g_hoist_stripping = true;
                    defer g_hoist_stripping = false;
                    var hbuf: std.ArrayList(u8) = .empty;
                    defer hbuf.deinit(alloc);
                    try emitInstruction(m, names, decs, inst, compat.listWriter(&hbuf, alloc), alloc, is_frag, ovid, cbuffers, textures, storage_buffers, arraylen_buf_index);
                    try common.writeHoistedAssign(w, hbuf.items, names.get(rid) orelse "");
                    return;
                }
            }
        }
    }
    switch (inst.op) {
        .Variable => {
            if (inst.words.len < 4) return;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Output and is_frag) {
                const ri = inst.words[2];
                const tn = try mslType(m, inst.words[1], names, alloc);
                const arr = try mslGetArraySuffix(m, inst.words[1]);
                try w.print("    {s} {s}{s};\n", .{ tn, names.get(ri) orelse "var", arr });
                return;
            }
            if (sc == .Input or sc == .Output or sc == .Uniform or sc == .UniformConstant or sc == .Workgroup) return;
            const ri = inst.words[2];
            // Const-initialized array local: read-only → promoted to a
            // module-scope `constant` (no local decl; reads resolve via the
            // alias). Mutated → brace-initialize in place so it stays a mutable
            // local without an invalid C-array copy of the initializer.
            if (analyzeLocalConstArray(m, inst)) |info| {
                if (!info.mutated) return;
                // A1: if this mutable local is ALSO the source of a whole-array
                // value copy (its id roots a whole-array OpLoad), it must be a
                // `spvUnsafeArray<…>` — a C-array cannot be copy-assigned in
                // Metal, so `spvUnsafeArray dst = cArraySrc;` would not compile.
                // Brace-init the template via its `{…}` constructor.
                if (arrayLoadedAsValue(m, ri)) {
                    const pointee = blk: {
                        const ptr = getDef(m, inst.words[1]) orelse break :blk inst.words[1];
                        break :blk if (ptr.op == .TypePointer and ptr.words.len >= 4) ptr.words[3] else inst.words[1];
                    };
                    const vt = try mslValueType(m, pointee, names, alloc);
                    try w.print("    {s} {s} = {s}(", .{ vt, names.get(ri) orelse "var", vt });
                    try writeMslConstInit(m, names, w, info.init_id, alloc);
                    try w.writeAll(");\n");
                    return;
                }
                const tn = try mslType(m, inst.words[1], names, alloc);
                const arr = try mslGetArraySuffix(m, inst.words[1]);
                try w.print("    {s} {s}{s} = ", .{ tn, names.get(ri) orelse "var", arr });
                try writeMslConstInit(m, names, w, info.init_id, alloc);
                try w.writeAll(";\n");
                return;
            }
            // Whole-array value-copy destination (`float local[N] = LUT;`):
            // declare as `spvUnsafeArray<…>` (no C-array suffix) so the
            // following whole-array store is a legal struct assignment.
            if (localArrayValueCopyDest(m, inst) or localArrayValueCopySource(m, inst)) {
                const pointee = blk: {
                    const ptr = getDef(m, inst.words[1]) orelse break :blk inst.words[1];
                    break :blk if (ptr.op == .TypePointer and ptr.words.len >= 4) ptr.words[3] else inst.words[1];
                };
                const vt = try mslValueType(m, pointee, names, alloc);
                try w.print("    {s} {s};\n", .{ vt, names.get(ri) orelse "var" });
                return;
            }
            const tn = try mslType(m, inst.words[1], names, alloc);
            const arr = try mslGetArraySuffix(m, inst.words[1]);
            // #476: OpVariable Function with an Initializer operand (word[4]) — emit it,
            // else the local reads zero/garbage before any store (silent-wrong). Mirrors
            // HLSL. (Array/composite inits are handled by the analyzeLocalConstArray path
            // above; this covers the scalar/simple-constant case.)
            if (inst.words.len >= 5) {
                if (names.get(inst.words[4])) |in| {
                    try w.print("    {s} {s}{s} = {s};\n", .{ tn, names.get(ri) orelse "var", arr, in });
                    return;
                }
            }
            try w.print("    {s} {s}{s};\n", .{ tn, names.get(ri) orelse "var", arr });
        },
        .Load => {
            // #500 recursive flatten: reconstruct a whole-/sub-struct load of a
            // flattened Input BEFORE the is_special branch (sub-struct loads have
            // pid = OpAccessChain, not a Variable, so is_special is false).
            if (try tryReconstructFlatStructLoad(m, names, w, alloc, inst)) return;
            const rn = names.get(inst.words[2]) orelse "v";
            const pid = inst.words[3];
            const pn = names.get(pid) orelse "var";
            const pi = getDef(m, pid);
            var is_special = false;
            if (pi) |p| {
                if (p.op == .Variable and p.words.len >= 4) {
                    const sc: spirv.StorageClass = @enumFromInt(p.words[3]);
                    if (sc == .UniformConstant or sc == .Output or sc == .Input) is_special = true;
                }
            }
            if (is_special) {
                // gl_HelperInvocation has no MSL input attribute; Metal spells it
                // as the simd_is_helper_thread() intrinsic. Alias the load result
                // to an inline call so every use reads the current helper state,
                // mirroring the HLSL IsHelperLane() path (spirv_to_hlsl.zig). The
                // builtin Input variable is never declared or threaded, so aliasing
                // the load is the whole fix. Not gated on is_frag: HelperInvocation
                // is a fragment-only builtin (spirv-val enforces it) but its load
                // often lives in a NON-entry helper function, which emits with
                // is_frag=false; the intrinsic is valid in any fragment-pipeline fn.
                const is_helper = if (builtinOf(decs, pid)) |bi|
                    bi == @intFromEnum(spirv.BuiltIn.helper_invocation)
                else
                    false;
                const a = try alloc.dupe(u8, if (is_helper) "simd_is_helper_thread()" else pn);
                if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
            } else {
                // B4: a whole-array load is a VALUE copy. Spell it
                // `spvUnsafeArray<…>` (mslType would drop `[N]` → an illegal
                // scalar-from-array load) ONLY when the load's source is itself
                // declared `spvUnsafeArray` — a value-copied const global or a
                // value-copied function local. If the source is some other shape
                // (a plain `constant T[N]` C-array, a UBO/SSBO member, an array
                // function param, …) the template spelling would NOT match the
                // C-array source, so emitting it would be silent-wrong; fail loud
                // instead. Non-array loads fall through to mslType unchanged.
                const rt = getDef(m, inst.words[1]);
                if (rt != null and rt.?.op == .TypeArray) {
                    if (!arrayLoadRootIsUnsafeArray(m, pid))
                        return error.UnsupportedWholeArrayValueLoad;
                }
                const rtt = try mslValueType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s} = ", .{ rtt, rn });
                try writeResolvePointer(m, names, pid, true, w);
                try w.writeAll(";\n");
            }
        },
        .Store => {
            if (inst.words.len < 3) return;
            // Skip the whole-array initializer store of a const-array local: the
            // values are materialized at module scope (promoted) or folded into
            // the declaration (brace-initialized). Emitting `a = vC;` would be an
            // invalid C-array copy in Metal.
            if (getDef(m, inst.words[1])) |dst| {
                if (dst.op == .Variable) {
                    if (analyzeLocalConstArray(m, dst)) |info| {
                        if (inst.words[2] == info.init_id) return;
                    }
                }
            }
            // A store THROUGH a row_major matrix would need a transposed scatter
            // (you cannot assign through `transpose(...)`). Fail loudly rather
            // than emit a plain store to the wrong, transposed locations.
            if (getDef(m, inst.words[1])) |ptr| {
                if (ptr.op == .AccessChain and ptr.words.len >= 4 and
                    findRowMajorMatrix(m, ptr.words[3], ptr.words[4..]) != null)
                    return error.UnsupportedRowMajorMatrixStore;
            }
            // Matrix-typed vertex output: the main0_out field is flattened to
            // per-column vectors; scatter the store (out.m22_0 = v[0]; out.m22_1
            // = v[1]; ...), the spirv-cross idiom.
            if (getDef(m, inst.words[1])) |dst| {
                if (dst.op == .Variable and dst.words.len >= 4 and
                    @as(spirv.StorageClass, @enumFromInt(dst.words[3])) == .Output)
                {
                    const pptr = getDef(m, dst.words[1]);
                    if (pptr != null and pptr.?.op == .TypePointer and pptr.?.words.len >= 4) {
                        const pty = getDef(m, pptr.?.words[3]);
                        if (pty != null and pty.?.op == .TypeMatrix and pty.?.words.len >= 4) {
                            const cols = pty.?.words[3];
                            const tgt = names.get(inst.words[1]) orelse "out";
                            const val = names.get(inst.words[2]) orelse "0";
                            var ci: u32 = 0;
                            while (ci < cols) : (ci += 1) {
                                try w.print("    {s}_{d} = {s}[{d}];\n", .{ tgt, ci, val, ci });
                            }
                            return;
                        }
                    }
                }
            }
            const on = names.get(inst.words[2]) orelse "0";
            try w.writeAll("    ");
            try writeResolvePointer(m, names, inst.words[1], false, w);
            try w.print(" = {s};\n", .{on});
        },
        // OpUndef is folded to a zero literal in collectNames (module-scope undef
        // bypasses this switch entirely; this no-op covers any non-standard in-body
        // OpUndef, whose value the fold already inlined at its use sites).
        .Undef => {},
        .CopyObject => {
            if (inst.words.len < 4) return;
            const sn = names.get(inst.words[3]) orelse "0";
            const a = try alloc.dupe(u8, sn);
            if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
        },
        .CopyMemory => {
            if (inst.words.len < 3) return;
            try w.writeAll("    ");
            try writeResolvePointer(m, names, inst.words[1], false, w);
            try w.writeAll(" = ");
            try writeResolvePointer(m, names, inst.words[2], false, w);
            try w.writeAll(";\n");
        },
        .Phi => {
            if (inst.words.len < 4) return;
            // Already materialized as a `_phi` var by the selection handler — keep
            // that name; aliasing to a branch-local incoming value would be wrong.
            if (g_materialized_phis) |mp| if (mp.contains(inst.words[2])) return;
            // A #413-hoisted phi (declared above the loop, assigned in each arm) and a
            // loop-header phi (declared and carried by tryEmitLoopPhiDeclMSL) already
            // have a correct variable and correct assignments under their own name --
            // the same two exclusions the phi prologue makes. Keep that name. Aliasing
            // them to an incoming value discards a correct materialization: in
            // graphicsfuzz_039 the if/else merge is hoisted into `v34`, assigned in both
            // arms, and this arm then re-pointed it at the TRUE arm's local `v27`, so the
            // loop-merge copy after the `if` emitted `v81_lm = v27;` -- out of scope
            // there, and the false arm's value silently dropped where it is in scope.
            {
                const owned = (if (g_hoisted_ids) |h| h.contains(inst.words[2]) else false) or
                    (if (g_phi_hdr) |ph| ph.get(inst.words[2]) != null else false);
                if (owned) return;
            }
            const fv = inst.words[3];
            // Aliasing to incoming[0] is only sound when every predecessor carries the
            // SAME id -- then the phi is degenerate and the choice does not matter. With
            // distinct incoming values it silently yields the FIRST predecessor's value on
            // every path. Refuse instead of miscompiling.
            {
                var pi: usize = 5;
                while (pi < inst.words.len) : (pi += 2) {
                    if (inst.words[pi] != fv) return error.UnsupportedPhiAlias;
                }
            }
            if (names.get(fv)) |sn| {
                const a = try alloc.dupe(u8, sn);
                if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
            } else {
                const a = try std.fmt.allocPrint(alloc, "v{d}", .{fv});
                if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
            }
        },
        .AccessChain => {
            const ri = inst.words[2];
            const bi = inst.words[3];
            const ex = try buildAccessExpr(m, names, bi, inst.words[4..], alloc);
            if (names.fetchPut(ri, ex) catch null) |old| alloc.free(old.value);
        },
        .FAdd, .IAdd => try common.emitBinOp(m, names, inst, "+", w, alloc, mslType),
        .FSub, .ISub => try common.emitBinOp(m, names, inst, "-", w, alloc, mslType),
        .FMul, .IMul => try common.emitBinOp(m, names, inst, "*", w, alloc, mslType),
        .FDiv, .SDiv, .UDiv => try common.emitBinOp(m, names, inst, "/", w, alloc, mslType),
        .UMod, .SRem => try common.emitBinOp(m, names, inst, "%", w, alloc, mslType),
        // OpSMod is floored (sign of the DIVISOR); Metal `%` is truncated (sign of the
        // dividend = OpSRem), so `((x % y) + y) % y` adjusts it to floored for every sign
        // combination. Componentwise. Matches spirv-cross's spvSMod helper. Bare `%` was a
        // silent miscompile on opposite-sign operands (glslang emits OpSMod for GLSL `int %`). (#170)
        .SMod => try emitSMod(m, names, inst, w, alloc),
        .FRem => {
            // OpFRem takes the sign of operand 1 (the dividend) — exactly C/Metal fmod.
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const lhs = try resolvePointer(m, names, inst.words[3], alloc);
            defer alloc.free(lhs);
            const rhs = try resolvePointer(m, names, inst.words[4], alloc);
            defer alloc.free(rhs);
            try w.print("    {s} {s} = fmod({s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "r", lhs, rhs });
        },
        .FMod => {
            // OpFMod takes the sign of operand 2 (the divisor), which is GLSL mod()
            // semantics — NOT Metal fmod() (sign of the dividend). They differ for
            // operands of opposite sign, so lower to the sign-correct expansion the
            // way spirv-cross does: x - y * floor(x / y).
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const lhs = try resolvePointer(m, names, inst.words[3], alloc);
            defer alloc.free(lhs);
            const rhs = try resolvePointer(m, names, inst.words[4], alloc);
            defer alloc.free(rhs);
            const rn = names.get(inst.words[2]) orelse "r";
            try w.print("    {s} {s} = {s} - {s} * floor({s} / {s});\n", .{ rtt, rn, lhs, rhs, lhs, rhs });
        },
        .FNegate, .SNegate => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = -{s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .VectorExtractDynamic => {
            // Extract a component from a vector by a (possibly non-constant) index —
            // e.g. matrixColumn[i]. Metal spells this vec[idx]; without this arm it
            // fell through to `// unhandled op 77` and produced undeclared identifiers.
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const vec = names.get(inst.words[3]) orelse "v";
            const idx = names.get(inst.words[4]) orelse "0";
            try w.print("    {s} {s} = {s}[{s}];\n", .{ rtt, names.get(inst.words[2]) orelse "e", vec, idx });
        },
        .VectorTimesScalar, .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix => try common.emitBinOp(m, names, inst, "*", w, alloc, mslType),
        .Dot => try common.emitCall(m, names, inst, "dot", w, alloc, mslType),
        .Transpose => try common.emitCall(m, names, inst, "transpose", w, alloc, mslType),
        .OuterProduct => {
            // Metal has no outerProduct builtin. Build the matrix column by column:
            // SPIR-V OpOuterProduct's result column j is v1 * v2[j], and Metal
            // matrices are column-major (matCxR(col0, col1, …)), so this is exact.
            // Column count = v2's component count. Without this arm it fell through
            // to `// unhandled op 147`, leaving the result id undefined.
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const v1 = names.get(inst.words[3]) orelse "a";
            const v2 = names.get(inst.words[4]) orelse "b";
            const v2_val = getDef(m, inst.words[4]);
            const v2_ty = if (v2_val) |d| (if (d.words.len > 1) getDef(m, d.words[1]) else null) else null;
            const cols: u32 = if (v2_ty) |t| (if (t.op == .TypeVector and t.words.len > 3) t.words[3] else 2) else 2;
            try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", rtt });
            var j: u32 = 0;
            while (j < cols) : (j += 1) {
                if (j > 0) try w.writeAll(", ");
                try w.print("{s} * {s}[{d}]", .{ v1, v2, j });
            }
            try w.writeAll(");\n");
        },
        .FOrdEqual, .IEqual => try common.emitBinOp(m, names, inst, "==", w, alloc, mslType),
        .FUnordEqual => try emitUnordEqual(m, names, inst, w, alloc),
        .FUnordNotEqual, .INotEqual => try common.emitBinOp(m, names, inst, "!=", w, alloc, mslType),
        .FOrdNotEqual => try emitOrdNotEqual(m, names, inst, w, alloc),
        .FOrdLessThan, .SLessThan, .ULessThan => try common.emitBinOp(m, names, inst, "<", w, alloc, mslType),
        .FOrdGreaterThan, .SGreaterThan, .UGreaterThan => try common.emitBinOp(m, names, inst, ">", w, alloc, mslType),
        .FOrdLessThanEqual, .SLessThanEqual, .ULessThanEqual => try common.emitBinOp(m, names, inst, "<=", w, alloc, mslType),
        .FOrdGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try common.emitBinOp(m, names, inst, ">=", w, alloc, mslType),
        // #170: unordered float inequalities are TRUE on NaN, so `!(ordered complement)`,
        // not the naive ordered op (false on NaN = plausible-but-wrong, as spirv-cross
        // emits). See emitNegatedCompare. OpFUnordEqual is TRUE on NaN too; it has no
        // ordered complement (`!=` is true on NaN), so it goes through emitUnordEqual
        // (isunordered(a,b) || a==b). OpFUnordNotEqual is already exact on `!=`
        // (Metal/HLSL/GLSL != is true on NaN, matching the opcode).
        .FUnordLessThan => try emitNegatedCompare(m, names, inst, ">=", w, alloc),
        .FUnordGreaterThan => try emitNegatedCompare(m, names, inst, "<=", w, alloc),
        .FUnordLessThanEqual => try emitNegatedCompare(m, names, inst, ">", w, alloc),
        .FUnordGreaterThanEqual => try emitNegatedCompare(m, names, inst, "<", w, alloc),
        .LogicalOr => try common.emitBinOp(m, names, inst, "||", w, alloc, mslType),
        .LogicalAnd => try common.emitBinOp(m, names, inst, "&&", w, alloc, mslType),
        .IsNan => try common.emitCall(m, names, inst, "isnan", w, alloc, mslType),
        .IsInf => try common.emitCall(m, names, inst, "isinf", w, alloc, mslType),
        .LogicalNot => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = !{s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .Select => {
            // A2: a Select whose result type is an array is a whole-array VALUE
            // (`float la[N] = cond ? A : B;`). mslType would drop `[N]` → an
            // illegal scalar Select; use the spvUnsafeArray spelling so the
            // result (and its dest, declared via localArrayValueCopyDest) match.
            const rtt = try mslValueType(m, inst.words[1], names, alloc);
            const cond_name = mslExprName(m, names, inst.words[3], alloc);
            const true_name = mslExprName(m, names, inst.words[4], alloc);
            const false_name = mslExprName(m, names, inst.words[5], alloc);
            // Metal doesn't support ternary with vector bool — use select()
            const cond_type_str = blk: {
                const cond_def = getDef(m, inst.words[3]);
                if (cond_def) |cd| {
                    if (cd.words.len > 1) {
                        break :blk mslType(m, cd.words[1], names, alloc) catch "bool";
                    }
                }
                break :blk "unknown";
            };
            if (std.mem.startsWith(u8, cond_type_str, "bool") and !std.mem.eql(u8, cond_type_str, "bool")) {
                // Vector bool (bool2/3/4): use Metal select(false_val, true_val, bvec)
                try w.print("    {s} {s} = select({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", false_name, true_name, cond_name });
            } else {
                try w.print("    {s} {s} = ({s}) ? {s} : {s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", cond_name, true_name, false_name });
            }
        },
        .BitwiseOr => try common.emitBinOp(m, names, inst, "|", w, alloc, mslType),
        .BitwiseXor => try common.emitBinOp(m, names, inst, "^", w, alloc, mslType),
        .BitwiseAnd => try common.emitBinOp(m, names, inst, "&", w, alloc, mslType),
        .ShiftRightLogical, .ShiftRightArithmetic => try common.emitBinOp(m, names, inst, ">>", w, alloc, mslType),
        .ShiftLeftLogical => try common.emitBinOp(m, names, inst, "<<", w, alloc, mslType),
        .Not => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ~{s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .BitReverse => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = reverse_bits({s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .BitCount => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            // Metal's popcount returns the OPERAND's type (e.g. uint2), but OpBitCount's
            // result is signed int (GLSL `genIType bitCount(genUType)`); a vector result
            // then needs an explicit constructor cast (int2(popcount(uint2))) or Metal
            // rejects `int2 v = popcount(uint2)` ("cannot initialize int2 with uint2").
            // The cast is a no-op when the types already match. Mirrors spirv-cross
            // (int2(popcount(...))) and zioshade's WGSL backend (vec2i(countOneBits(...))).
            try w.print("    {s} {s} = {s}(popcount({s}));\n", .{ rtt, names.get(inst.words[2]) orelse "v", rtt, names.get(inst.words[3]) orelse "0" });
        },
        // OpBitFieldInsert: base, insert, offset, count → MSL insert_bits(base, insert, uint
        // offset, uint bits). MSL takes the offset/width as uint, so cast them.
        .BitFieldInsert => {
            if (inst.words.len < 7) return;
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = insert_bits({s}, {s}, uint({s}), uint({s}));\n", .{
                rtt,                                 names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "0", names.get(inst.words[4]) orelse "0",
                names.get(inst.words[5]) orelse "0", names.get(inst.words[6]) orelse "0",
            });
        },
        // OpBitFieldSExtract / OpBitFieldUExtract: value, offset, count → extract_bits
        // (overloaded by the value's signedness — sign- vs zero-extend); offset/width are uint.
        .BitFieldSExtract, .BitFieldUExtract => {
            if (inst.words.len < 6) return;
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = extract_bits({s}, uint({s}), uint({s}));\n", .{
                rtt,                                 names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "0", names.get(inst.words[4]) orelse "0",
                names.get(inst.words[5]) orelse "0",
            });
        },
        .ConvertSToF, .ConvertUToF, .ConvertFToS, .ConvertFToU, .UConvert, .SConvert, .FConvert => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}({s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", rtt, names.get(inst.words[3]) orelse "0" });
        },
        .Bitcast => {
            // OpBitcast REINTERPRETS the bit pattern (floatBitsToUint, uintBitsToFloat,
            // …); it does not numerically convert. Metal spells that as_type<T>(x). A
            // plain T(x) constructor would round/convert and silently produce the wrong
            // value (e.g. floatBitsToUint(2.5) -> 2 instead of 0x40200000).
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = as_type<{s}>({s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", rtt, names.get(inst.words[3]) orelse "0" });
        },
        .CompositeConstruct => {
            // C6: an array OpCompositeConstruct (`float arr[N] = float[](a,…);`)
            // is a whole-array VALUE. mslType would drop `[N]` and emit a bogus
            // scalar ctor `float(a, b, c)`; instead spell the spvUnsafeArray
            // template and brace-init its elements — `spvUnsafeArray<T,N>({…})`
            // (the spirv-cross idiom). Its dest local is declared spvUnsafeArray
            // via localArrayValueCopyDest (which recognises a CompositeConstruct
            // store value of array type). Non-array constructs are unchanged.
            const rt = getDef(m, inst.words[1]);
            if (rt != null and rt.?.op == .TypeArray) {
                const vt = try mslValueType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s} = {s}({{ ", .{ vt, names.get(inst.words[2]) orelse "v", vt });
                for (inst.words[3..], 0..) |cid, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(names.get(cid) orelse "0");
                }
                try w.writeAll(" });\n");
                return;
            }
            const rtt = try mslType(m, inst.words[1], names, alloc);
            if (rt != null and rt.?.op == .TypeStruct) {
                // Metal structs have no call-style constructor (`Light(a,b,c)` fails
                // to compile); use C++ aggregate brace-init `Light{ a, b, c }`.
                try w.print("    {s} {s} = {s}{{ ", .{ rtt, names.get(inst.words[2]) orelse "v", rtt });
                for (inst.words[3..], 0..) |cid, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(names.get(cid) orelse "0");
                }
                try w.writeAll(" };\n");
                return;
            }
            try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", rtt });
            for (inst.words[3..], 0..) |cid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(names.get(cid) orelse "0");
            }
            try w.writeAll(");\n");
        },
        .CompositeExtract => {
            // Skip if source is a decomposed std450 struct (FrexpStruct/ModfStruct)
            if (inst.words.len > 3) {
                const src_def = getDef(m, inst.words[3]);
                if (src_def) |sd| {
                    if (sd.op == .ExtInst and sd.words.len >= 5) {
                        const ext_op = sd.words[4];
                        if (ext_op == 52 or ext_op == 36) return;
                    }
                }
            }
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const comp = names.get(inst.words[3]) orelse "c";
            try w.print("    {s} {s} = {s}", .{ rtt, names.get(inst.words[2]) orelse "v", comp });
            var cur_type = common.getTypeOf(m, inst.words[3]);
            for (inst.words[4..]) |index| {
                const is_vec = if (cur_type) |ptv| blk: {
                    const pti = getDef(m, ptv);
                    break :blk pti != null and pti.?.op == .TypeVector;
                } else false;
                const is_struct = if (cur_type) |ptv| blk: {
                    const pti = getDef(m, ptv);
                    break :blk pti != null and pti.?.op == .TypeStruct;
                } else false;
                if (is_vec) {
                    try w.writeAll(switch (index) {
                        0 => ".x",
                        1 => ".y",
                        2 => ".z",
                        3 => ".w",
                        else => ".x",
                    });
                    if (cur_type) |ptv| {
                        const pti = getDef(m, ptv);
                        if (pti) |tinst| cur_type = tinst.words[2];
                    }
                } else if (is_struct) {
                    var mname_buf: [32]u8 = undefined;
                    const mname = getMemberName(m, cur_type.?, index, &mname_buf);
                    try w.print(".{s}", .{mname});
                    if (cur_type) |ptv| {
                        const pti = getDef(m, ptv);
                        if (pti) |tinst| {
                            if (index + 2 < tinst.words.len) cur_type = tinst.words[index + 2];
                        }
                    }
                } else {
                    try w.print("[{d}]", .{index});
                    if (cur_type) |ptv| {
                        const pti = getDef(m, ptv);
                        if (pti) |tinst| cur_type = tinst.words[2];
                    }
                }
            }
            try w.writeAll(";\n");
        },
        .CompositeInsert => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rname = names.get(inst.words[2]) orelse "v";
            const object = names.get(inst.words[3]) orelse "obj";
            const composite = names.get(inst.words[4]) orelse "comp";
            try w.print("    {s} {s} = {s};\n", .{ rtt, rname, composite });
            // #475: walk the type chain per-index level (was a single is_vec flag that
            // emitted [0] for struct members = Metal compile error). Mirrors WGSL/HLSL.
            try w.print("    {s}", .{rname});
            // Resolve the composite operand's type (dereference pointers).
            var cur_type_id: ?u32 = null;
            if (getDef(m, inst.words[4])) |comp_def| {
                if (comp_def.words.len > 1) {
                    var tid = comp_def.words[1];
                    if (getDef(m, tid)) |ti| {
                        if (ti.op == .TypePointer and ti.words.len > 3) tid = ti.words[3];
                    }
                    cur_type_id = tid;
                }
            }
            for (inst.words[5..]) |index| {
                if (cur_type_id) |ctid| {
                    if (getDef(m, ctid)) |ci| switch (ci.op) {
                        .TypeVector => {
                            try w.writeAll(swizzleChar(index));
                            cur_type_id = if (ci.words.len > 2) ci.words[2] else null;
                            continue;
                        },
                        .TypeStruct => {
                            var mb: [32]u8 = undefined;
                            try w.print(".{s}", .{getMemberName(m, ctid, index, &mb)});
                            cur_type_id = if (ci.words.len > 2 + index) ci.words[2 + index] else null;
                            continue;
                        },
                        else => {
                            try w.print("[{d}]", .{index});
                            cur_type_id = if (ci.words.len > 2) ci.words[2] else null;
                            continue;
                        },
                    };
                }
                try w.print("[{d}]", .{index});
            }
            try w.print(" = {s};\n", .{object});
        },
        .VectorShuffle => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const v1 = names.get(inst.words[3]) orelse "v1";
            const v2 = names.get(inst.words[4]) orelse "v2";
            // OpVectorShuffle selects components from the concatenation [v1, v2]: a
            // selector 0..N1-1 indexes v1, N1..N1+N2-1 indexes v2, where N1 is the
            // COMPONENT COUNT OF v1 (not a fixed 4). Reading v1's actual width matters
            // whenever v1 is a vec2/vec3 (e.g. a `v.xy = expr` swizzle-store lowers to a
            // shuffle of the vec3 lvalue with a vec2): a hardcoded split of 4 emitted an
            // out-of-bounds `v1[3]` and shifted every later selector, silently miscompiling
            // the write.
            const n1: u32 = blk: {
                const d = getDef(m, inst.words[3]) orelse break :blk 4;
                if (d.words.len < 2) break :blk 4;
                break :blk typeRank(m, d.words[1]);
            };
            try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", rtt });
            for (inst.words[5..], 0..) |sel, i| {
                if (i > 0) try w.writeAll(", ");
                // A 0xFFFFFFFF selector is "undefined"; spirv-cross reads v1[0]. Keep in bounds.
                if (sel == 0xFFFFFFFF) {
                    try w.print("{s}[0]", .{v1});
                } else if (sel < n1) {
                    try w.print("{s}[{d}]", .{ v1, sel });
                } else {
                    try w.print("{s}[{d}]", .{ v2, sel - n1 });
                }
            }
            try w.writeAll(");\n");
        },
        .DPdx, .DPdxFine, .DPdxCoarse => try common.emitCall(m, names, inst, "dfdx", w, alloc, mslType),
        .DPdy, .DPdyFine, .DPdyCoarse => try common.emitCall(m, names, inst, "dfdy", w, alloc, mslType),
        .Fwidth, .FwidthFine, .FwidthCoarse => try common.emitCall(m, names, inst, "fwidth", w, alloc, mslType),
        .All => try common.emitCall(m, names, inst, "all", w, alloc, mslType),
        .Any => try common.emitCall(m, names, inst, "any", w, alloc, mslType),
        .ExtInst => {
            if (inst.words.len < 5) return;
            const instruction = inst.words[4];
            // FrexpStruct (52) and ModfStruct (36) return structs — decompose to two-arg form
            if (instruction == 52 or instruction == 36) {
                const result_id = inst.words[2];
                const input_name = names.get(inst.words[5]) orelse "x";
                const func_name: []const u8 = if (instruction == 52) "frexp" else "modf";
                var fract_name: []const u8 = "_fract";
                var second_name: []const u8 = "_second";
                var fract_type: []const u8 = "float";
                var second_type: []const u8 = "int";
                // Find downstream CompositeExtracts for member names/types
                {
                    var j: usize = 0;
                    for (m.instructions, 0..) |mi, i| {
                        if (mi.op == .ExtInst and mi.words.len >= 3 and mi.words[2] == result_id) {
                            j = i + 1;
                            break;
                        }
                    }
                    while (j < m.instructions.len) : (j += 1) {
                        const ni = m.instructions[j];
                        if (ni.op == .FunctionEnd) break;
                        if (ni.op == .CompositeExtract and ni.words.len >= 5 and ni.words[3] == result_id) {
                            const member_idx = ni.words[4];
                            const ce_name = names.get(ni.words[2]) orelse "v";
                            const ce_type = try mslType(m, ni.words[1], names, alloc);
                            if (member_idx == 0) {
                                fract_name = ce_name;
                                fract_type = ce_type;
                            } else if (member_idx == 1) {
                                second_name = ce_name;
                                second_type = ce_type;
                            }
                        }
                    }
                }
                try w.print("    {s} {s};\n", .{ second_type, second_name });
                try w.print("    {s} {s} = {s}({s}, {s});\n", .{ fract_type, fract_name, func_name, input_name, second_name });
            } else if (instruction == 11 or instruction == 12) {
                if (inst.words.len < 6) return; // one operand
                // radians(11) / degrees(12) have NO MSL builtin. Lower to the defining
                // multiply like spirv-cross: radians(d) = d * pi/180, degrees(r) =
                // r * 180/pi. The constant is cast to the (possibly vector) result type
                // so a floatN operand multiplies componentwise without a double literal.
                const rt = try mslType(m, inst.words[1], names, alloc);
                const rn = names.get(inst.words[2]) orelse "v";
                const x = names.get(inst.words[5]) orelse "x";
                const k: []const u8 = if (instruction == 11) "0.01745329251994329577" else "57.29577951308232088";
                try w.print("    {s} {s} = {s} * {s}({s});\n", .{ rt, rn, x, rt, k });
            } else if (instruction == 34) {
                if (inst.words.len < 6) return; // one operand
                // GLSL inverse(matN) — Metal has no matrix inverse() builtin, so call the
                // generated spvInverseNxN helper (emitted once in the preamble).
                const rt = try mslType(m, inst.words[1], names, alloc);
                const rn = names.get(inst.words[2]) orelse "v";
                const x = names.get(inst.words[5]) orelse "x";
                if (matrixInverseDim(m, inst.words[1])) |d| {
                    try w.print("    {s} {s} = spvInverse{d}x{d}({s});\n", .{ rt, rn, d, d, x });
                } else {
                    // Non-square / unsupported — should be unreachable for valid inverse().
                    try w.print("    {s} {s} = {s}; // inverse: unsupported matrix dimension\n", .{ rt, rn, x });
                }
            } else if (instruction == 58 or instruction == 62) {
                if (inst.words.len < 6) return; // one operand
                // packHalf2x16(58) / unpackHalf2x16(62) have NO MSL builtin — Metal's
                // pack_float_to_* / unpack_*_to_float cover only unorm/snorm. Convert
                // through `half` + `as_type` like spirv-cross. GLSL fixes the types with
                // no overloads (packHalf2x16: vec2 -> uint; unpackHalf2x16: uint -> vec2),
                // so the result/operand types are hardcoded:
                //   packHalf2x16(vec2)   -> as_type<uint>(half2(x))
                //   unpackHalf2x16(uint) -> float2(as_type<half2>(x))
                const rn = names.get(inst.words[2]) orelse "v";
                const x = names.get(inst.words[5]) orelse "x";
                if (instruction == 58) {
                    try w.print("    uint {s} = as_type<uint>(half2({s}));\n", .{ rn, x });
                } else {
                    try w.print("    float2 {s} = float2(as_type<half2>({s}));\n", .{ rn, x });
                }
            } else if (instruction == 73 or instruction == 74 or instruction == 75) {
                if (inst.words.len < 6) return; // these ExtInsts have exactly one operand
                // findLSB / findMSB(signed) / findMSB(unsigned) — GLSL.std.450
                // FindILsb(73) / FindSMsb(74) / FindUMsb(75). These are NOT raw ctz/clz:
                // findMSB returns the MSB *index* (31 - clz for 32-bit), findLSB returns
                // -1 when the input is 0, and signed findMSB flips negatives first. Emit
                // the spirv-cross helper math inline, computed in the ARG type `at` (so
                // there is no mixed int/uint arithmetic — glslang gives FindUMsb/FindILsb
                // a signed result over an unsigned operand) and cast to the result type
                // `rt`, mirroring spirv-cross's `int(spvFindUMSB(x))`. `clz(at(0))` is the
                // bit width, so `clz(at(0)) - (clz(x) + at(1))` is the MSB index for any
                // width, and `select(…, at(-1), x == at(0))` supplies the -1-on-zero edge.
                const rt = try mslType(m, inst.words[1], names, alloc);
                const at = if (getDef(m, inst.words[5])) |ad| (if (ad.words.len > 1) try mslType(m, ad.words[1], names, alloc) else rt) else rt;
                const rn = names.get(inst.words[2]) orelse "v";
                const x = names.get(inst.words[5]) orelse "x";
                if (instruction == 73) {
                    try w.print("    {s} {s} = {s}(select(ctz({s}), {s}(-1), {s} == {s}(0)));\n", .{ rt, rn, rt, x, at, x, at });
                } else if (instruction == 75) {
                    try w.print("    {s} {s} = {s}(select(clz({s}(0)) - (clz({s}) + {s}(1)), {s}(-1), {s} == {s}(0)));\n", .{ rt, rn, rt, at, x, at, at, x, at });
                } else { // 74 — signed findMSB: flip negatives (v = x<0 ? ~x : x) first
                    const id = inst.words[2];
                    try w.print("    {s} _fmsb_{d} = select({s}, {s}(-1) - {s}, {s} < {s}(0));\n", .{ at, id, x, at, x, x, at });
                    try w.print("    {s} {s} = {s}(select(clz({s}(0)) - (clz(_fmsb_{d}) + {s}(1)), {s}(-1), _fmsb_{d} == {s}(0)));\n", .{ rt, rn, rt, at, id, at, at, id, at });
                }
            } else if (instruction == 76 or instruction == 77 or instruction == 78) {
                // Pull-model interpolation. Metal has NO free functions for these — the
                // interpolant must be queried as a METHOD on the `interpolant<>` stage-in
                // field (MSL 2.3+; the < 2.3 honest-error guard runs in spirvToMSL).
                //   76 InterpolateAtCentroid(p)   -> in.p.interpolate_at_centroid()
                //   77 InterpolateAtSample(p, s)   -> in.p.interpolate_at_sample(s)
                //   78 InterpolateAtOffset(p, o)   -> in.p.interpolate_at_offset(o + 0.4375)
                // The interpolant operand (words[5]) is the Input variable, which the
                // stage-input rename aliased to `in.<name>.interpolate_at_center()`; strip
                // that known suffix to recover the `in.<name>` base. If the operand is NOT
                // a wrapped top-level interpolant (e.g. an interface-block member or array
                // element — operand is an OpAccessChain result, never renamed), the strip
                // fails and we honest-error rather than emit a method call on a plain field.
                if (inst.words.len < 6) return;
                const rt = try mslType(m, inst.words[1], names, alloc);
                const rn = names.get(inst.words[2]) orelse "v";
                const raw = names.get(inst.words[5]) orelse return error.UnsupportedOp;
                if (!std.mem.endsWith(u8, raw, pull_model_center_suffix)) return error.UnsupportedOp;
                const base = raw[0 .. raw.len - pull_model_center_suffix.len];
                if (instruction == 76) {
                    try w.print("    {s} {s} = {s}.interpolate_at_centroid();\n", .{ rt, rn, base });
                } else if (instruction == 77) {
                    if (inst.words.len < 7) return; // needs the sample-index operand
                    const s = names.get(inst.words[6]) orelse "0";
                    try w.print("    {s} {s} = {s}.interpolate_at_sample({s});\n", .{ rt, rn, base, s });
                } else {
                    if (inst.words.len < 7) return; // needs the offset operand
                    const o = names.get(inst.words[6]) orelse "0";
                    try w.print("    {s} {s} = {s}.interpolate_at_offset({s} + 0.4375);\n", .{ rt, rn, base, o });
                }
            } else {
                try emitStd450(m, names, inst, instruction, w, alloc);
            }
        },
        .SampledImage => {
            const ri = inst.words[2];
            const iname = names.get(inst.words[3]) orelse "tex";
            const a = try alloc.dupe(u8, iname);
            if (names.fetchPut(ri, a) catch null) |old| alloc.free(old.value);
            // #491: record the sampler operand so ImageSample* uses it (not <image>Smplr).
            if (g_sampled_sampler) |ss| {
                if (inst.words.len > 4) {
                    if (names.get(inst.words[4])) |sname| {
                        ss.put(ri, alloc.dupe(u8, sname) catch return) catch {};
                    }
                }
            }
        },
        .OpImage => {
            // OpImage extracts image from sampled_image — in MSL, texture is already separate
            const ri = inst.words[2];
            const iname = names.get(inst.words[3]) orelse "tex";
            const a = try alloc.dupe(u8, iname);
            if (names.fetchPut(ri, a) catch null) |old| alloc.free(old.value);
        },
        .ImageSampleImplicitLod => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            // #491: the sampler is the OpSampledImage sampler operand for a bare
            // image+separate-sampler; else the paired <name>Smplr (resource).
            var samp: []const u8 = try std.fmt.allocPrint(alloc, "{s}Smplr", .{si});
            if (g_sampled_sampler) |ss| {
                if (ss.get(inst.words[3])) |s| samp = s;
            }
            // A Bias image operand (mask bit 0, value at words[6]) → MSL `bias(b)`.
            // GLSL's LOD bias is fragment-only; dropping it samples the wrong mip
            // level (silent-wrong, #170).
            var bias_suffix: []const u8 = "";
            if (inst.words.len > 6 and (inst.words[5] & 0x1) != 0) {
                bias_suffix = try std.fmt.allocPrint(alloc, ", bias({s})", .{names.get(inst.words[6]) orelse "0.0"});
            }
            // ConstOffset image operand (mask bit 3): MSL `.sample` takes it as a
            // trailing int2 arg (spirv-cross: `tex.sample(samp, uv, int2(1,2))`).
            // Position: skip Bias(1)/Lod(1)/Grad(2) words. Dropping it samples the
            // wrong texel — silent plausible-wrong (#170, same class as HLSL 8d5c972).
            var off_suffix: []const u8 = "";
            if (inst.words.len > 5 and (inst.words[5] & 0x8) != 0) {
                var off: usize = 6;
                if ((inst.words[5] & 0x1) != 0) off += 1; // Bias
                if ((inst.words[5] & 0x2) != 0) off += 1; // Lod
                if ((inst.words[5] & 0x4) != 0) off += 2; // Grad
                if (off < inst.words.len) {
                    const o = mslConstOffset(m, alloc, inst.words[off]);
                    if (o.len > 0) off_suffix = std.fmt.allocPrint(alloc, ", {s}", .{o}) catch "";
                }
            }
            // MSL: tex.sample(samp, coord). Arrayed textures pass the array layer
            // as a SEPARATE argument (coord.xy, uint(rint(coord.z)) for 2d_array).
            if (imageValueIsArrayed(m, inst.words[3])) {
                const args = try mslArrayedSampleArgs(alloc, coord, imageValueDim(m, inst.words[3]));
                try w.print("    {s} {s} = {s}.sample({s}, {s}{s}{s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, samp, args, bias_suffix, off_suffix });
            } else {
                try w.print("    {s} {s} = {s}.sample({s}, {s}{s}{s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, samp, coord, bias_suffix, off_suffix });
            }
        },
        // OpImageQueryLod (textureQueryLod): SampledImage, Coordinate → result vec2.
        // MSL calculate_clamped_lod (.x) + calculate_unclamped_lod (.y) — both MSL 2.2+.
        // Emitted unconditionally (spirvToMSL no longer honest-errors this; Metal 2.2 ships
        // on all modern macOS and MslCompileCheck uses the device's latest language version).
        // Arrayed textures need no layer split here — the LOD query is layer-agnostic
        // (unlike .sample, which passes the array layer as a separate argument).
        .ImageQueryLod => {
            if (inst.words.len < 5) return;
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            try w.print("    {s} {s} = {s}({s}.calculate_clamped_lod({s}Smplr, {s}), {s}.calculate_unclamped_lod({s}Smplr, {s}));\n", .{ rtt, names.get(inst.words[2]) orelse "v", rtt, si, si, coord, si, si, coord });
        },
        .ImageSampleDrefImplicitLod => {
            // Shadow texture: MSL uses .sample_compare(compare_sampler, coord, dref).
            // Arrayed: the layer is a SEPARATE arg between coord and dref
            // (coord.xy, uint(rint(coord.z)), dref) -- matching spirv-cross --msl.
            // ConstOffset (0x8) -> trailing int2 arg. Dref=words[5], mask=words[6]. (#170)
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            var samp: []const u8 = try std.fmt.allocPrint(alloc, "{s}Smplr", .{si});
            if (g_sampled_sampler) |ss| {
                if (ss.get(inst.words[3])) |s| samp = s;
            }
            const coord_name = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const coord = if (imageValueIsArrayed(m, inst.words[3]))
                try mslArrayedSampleArgs(alloc, coord_name, imageValueDim(m, inst.words[3]))
            else
                try std.fmt.allocPrint(alloc, "{s}{s}", .{ coord_name, mslDrefCoordSwizzle(m, inst.words[3], inst.words[4]) });
            var off_suffix: []const u8 = "";
            if (drefConstOffsetIdx(inst.words)) |oi| {
                const o = mslConstOffset(m, alloc, inst.words[oi]);
                if (o.len > 0) off_suffix = std.fmt.allocPrint(alloc, ", {s}", .{o}) catch "";
            }
            try w.print("    {s} {s} = {s}.sample_compare({s}, {s}, {s}{s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, samp, coord, dref, off_suffix });
        },
        .ImageSampleDrefExplicitLod => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord_name = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const coord = if (imageValueIsArrayed(m, inst.words[3]))
                try mslArrayedSampleArgs(alloc, coord_name, imageValueDim(m, inst.words[3]))
            else
                try std.fmt.allocPrint(alloc, "{s}{s}", .{ coord_name, mslDrefCoordSwizzle(m, inst.words[3], inst.words[4]) });
            // Lod value at words[7] (bit 0x2; Dref=words[5], mask=words[6]); the old
            // code hardcoded 0, silently sampling mip 0. ConstOffset (0x8) -> trailing
            // int2 arg after level(). (#170)
            const lod: []const u8 = if (inst.words.len > 7 and (inst.words[6] & 0x2) != 0)
                names.get(inst.words[7]) orelse "0"
            else
                "0";
            var off_suffix: []const u8 = "";
            if (drefConstOffsetIdx(inst.words)) |oi| {
                const o = mslConstOffset(m, alloc, inst.words[oi]);
                if (o.len > 0) off_suffix = std.fmt.allocPrint(alloc, ", {s}", .{o}) catch "";
            }
            try w.print("    {s} {s} = {s}.sample_compare({s}Smplr, {s}, {s}, level({s}){s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, dref, lod, off_suffix });
        },
        .ImageSampleProjImplicitLod => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            // Only 2D projective sampling is faithfully lowered (the .xy numerator
            // assumes 2D); textureProj(sampler3D) would drop the r-coordinate =
            // silent-wrong — honest-error instead. (Cube is frontend-guarded; WGSL
            // lowers all dims. Mirrors the proj-explicit-lod guard.) (#170)
            if (imageValueDim(m, inst.words[3]) != 1) return error.CrossCompileUnsupported;
            // Projected sample: divide xy by the coord's last component (.z/.w)
            const dvs = projDivisorSwizzle(m, inst.words[4]);
            // textureProjOffset carries a ConstOffset (mask 0x8 at words[5], offset at
            // words[6]); MSL sample takes the offset as a trailing int2 arg.
            if (inst.words.len > 6 and (inst.words[5] & 0x8) != 0) {
                try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}.xy / {s}{s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs, names.get(inst.words[6]) orelse "int2(0)" });
            } else {
                try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}.xy / {s}{s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs });
            }
        },
        .ImageSampleProjDrefImplicitLod => {
            // Projected shadow: divide xy by the coord's last component, compare depth.
            // OpImageSampleProjDref divides BOTH coord and Dref by the projective
            // divisor; emitting the raw Dref silently compares un-projected depth.
            // Matches the spirv-cross oracle and the WGSL/GLSL lowerings. ConstOffset
            // (0x8) -> trailing int2 arg. (#170, #470)
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const dvs = projDivisorSwizzle(m, inst.words[4]);
            var off_suffix: []const u8 = "";
            if (drefConstOffsetIdx(inst.words)) |oi| {
                const o = mslConstOffset(m, alloc, inst.words[oi]);
                if (o.len > 0) off_suffix = std.fmt.allocPrint(alloc, ", {s}", .{o}) catch "";
            }
            try w.print("    {s} {s} = {s}.sample_compare({s}Smplr, {s}.xy / {s}{s}, {s} / {s}{s}{s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs, dref, coord, dvs, off_suffix });
        },
        .ImageSampleProjDrefExplicitLod => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const dvs = projDivisorSwizzle(m, inst.words[4]);
            // Projective divide applies to the Dref too (see ProjDrefImplicitLod). Lod
            // value at words[7] (bit 0x2); was hardcoded 0. ConstOffset (0x8) -> trailing
            // int2 arg after level(). (#170, #470)
            const lod: []const u8 = if (inst.words.len > 7 and (inst.words[6] & 0x2) != 0)
                names.get(inst.words[7]) orelse "0"
            else
                "0";
            var off_suffix: []const u8 = "";
            if (drefConstOffsetIdx(inst.words)) |oi| {
                const o = mslConstOffset(m, alloc, inst.words[oi]);
                if (o.len > 0) off_suffix = std.fmt.allocPrint(alloc, ", {s}", .{o}) catch "";
            }
            try w.print("    {s} {s} = {s}.sample_compare({s}Smplr, {s}.xy / {s}{s}, {s} / {s}{s}, level({s}){s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs, dref, coord, dvs, lod, off_suffix });
        },
        .ImageSampleProjExplicitLod => {
            // Projected explicit LOD: sample with manual projection + lod. Divisor
            // is the coord's last component (.z for vec3, .w for vec4) — not always .w.
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dvs = projDivisorSwizzle(m, inst.words[4]);
            // Only 2D projective sampling is faithfully lowered here: the .xy
            // numerator and gradient2d constructor assume a 2D sampler. A 1D/3D
            // projective sample would drop coordinate components (and use the wrong
            // gradient rank) = silent-wrong — honest-error instead. (Cube is already
            // frontend-guarded. WGSL lowers all dims; this is an MSL-only limit.) (#170)
            if (imageValueDim(m, inst.words[3]) != 1) return error.CrossCompileUnsupported;
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                if (mask & 0x1 != 0) off += 1;
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    // Lod|ConstOffset (textureProjLodOffset): MSL sample takes the const
                    // offset as a trailing int2 arg after level(). Dropping it samples
                    // the un-offset texels.
                    if (mask & 0x8 != 0 and off + 1 < inst.words.len) {
                        try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}.xy / {s}{s}, level({s}), {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs, names.get(inst.words[off]) orelse "0", names.get(inst.words[off + 1]) orelse "int2(0)" });
                    } else {
                        try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}.xy / {s}{s}, level({s}));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs, names.get(inst.words[off]) orelse "0" });
                    }
                } else if (mask & 0x4 != 0 and off + 1 < inst.words.len) {
                    // textureProjGrad: sample with the manual perspective divide and
                    // explicit 2D gradients (gradient2d). Guaranteed 2D here — the
                    // dim guard above honest-errors 1D/3D (cube is frontend-guarded).
                    const dx = names.get(inst.words[off]) orelse "0";
                    const dy = names.get(inst.words[off + 1]) orelse "0";
                    // Grad|ConstOffset (textureProjGradOffset): MSL sample takes the const
                    // offset as a trailing int2 arg after the gradient.
                    if (mask & 0x8 != 0 and off + 2 < inst.words.len) {
                        try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}.xy / {s}{s}, gradient2d({s}, {s}), {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs, dx, dy, names.get(inst.words[off + 2]) orelse "int2(0)" });
                    } else {
                        try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}.xy / {s}{s}, gradient2d({s}, {s}));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs, dx, dy });
                    }
                } else {
                    try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}.xy / {s}{s}, level(0));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs });
                }
            } else {
                try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}.xy / {s}{s}, level(0));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord, dvs });
            }
        },
        .ImageSampleExplicitLod => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord_name = names.get(inst.words[4]) orelse "uv";
            // Arrayed textures split the array layer into a separate argument
            // BEFORE the level() (coord.xy, uint(rint(coord.z)), level(L)).
            const coord = if (imageValueIsArrayed(m, inst.words[3]))
                try mslArrayedSampleArgs(alloc, coord_name, imageValueDim(m, inst.words[3]))
            else
                coord_name;
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                if (mask & 0x1 != 0) off += 1;
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    // Lod (0x2) at words[off]; a trailing ConstOffset (0x8) at
                    // words[off+1] becomes the int2 offset arg. Dropping it samples
                    // the wrong texel (silent plausible-wrong, #170).
                    var lod_off: []const u8 = "";
                    if (mask & 0x8 != 0 and off + 1 < inst.words.len) {
                        const o = mslConstOffset(m, alloc, inst.words[off + 1]);
                        if (o.len > 0) lod_off = std.fmt.allocPrint(alloc, ", {s}", .{o}) catch "";
                    }
                    try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}, level({s}){s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, names.get(inst.words[off]) orelse "0", lod_off });
                } else if (mask & 0x4 != 0) {
                    // Grad (0x4): explicit gradients → MSL gradientNd(dPdx, dPdy).
                    // This arm previously had NO Grad case, so textureGrad fell
                    // through to level(0), DROPPING the gradients = wrong mip
                    // (valid-but-wrong). dPdx=words[off], dPdy=words[off+1]; a
                    // trailing ConstOffset (0x8) becomes the int2 offset arg.
                    //
                    // The gradient CONSTRUCTOR is dimension-specific: gradient2d /
                    // gradient3d / gradientcube. gradient2d on a float3 (3D/cube)
                    // gradient is invalid MSL — so pick by sampler Dim, and any
                    // operand bit beyond Grad|ConstOffset (or a 1D/Rect/Buffer
                    // sampler, which has no MSL mip-gradient sample) fails loud
                    // rather than mis-compile. A Grad mask whose two gradient
                    // operand words are missing (truncated/malformed SPIR-V) also
                    // fails loud rather than silently downgrading to level(0). (#170)
                    if (mask & ~@as(u32, 0x4 | 0x8) != 0) return error.CrossCompileUnsupported;
                    if (off + 1 >= inst.words.len) return error.CrossCompileUnsupported;
                    const grad_ctor: []const u8 = switch (imageValueDim(m, inst.words[3])) {
                        1 => "gradient2d",
                        2 => "gradient3d",
                        3 => "gradientcube",
                        else => return error.CrossCompileUnsupported,
                    };
                    const ddx = names.get(inst.words[off]) orelse "0";
                    const ddy = names.get(inst.words[off + 1]) orelse "0";
                    if (mask & 0x8 != 0) {
                        if (off + 2 >= inst.words.len) return error.CrossCompileUnsupported;
                        try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}, {s}({s}, {s}), {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, grad_ctor, ddx, ddy, names.get(inst.words[off + 2]) orelse "int2(0)" });
                    } else {
                        try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}, {s}({s}, {s}));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, grad_ctor, ddx, ddy });
                    }
                } else {
                    try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}, level(0));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord });
                }
            } else {
                try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}, level(0));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord });
            }
        },
        .ImageFetch => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord_name = names.get(inst.words[4]) orelse "0";
            // texelFetch on an ARRAY texture: split the array layer into a
            // separate integer arg after the spatial coordinate (matching
            // spirv-cross --msl). The lod/sample operand is preserved.
            if (imageValueIsArrayed(m, inst.words[3])) {
                const fetch_args = try mslArrayedFetchArgs(alloc, coord_name, imageValueDim(m, inst.words[3]));
                defer alloc.free(fetch_args);
                // OpImageFetch operands: result_type(1) result(2) image(3)
                // coord(4) [image_operands_mask(5) lod/sample_value(6) …].
                if (inst.words.len > 6) {
                    try w.print("    {s} {s} = {s}.read({s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, fetch_args, names.get(inst.words[6]) orelse "0" });
                } else {
                    try w.print("    {s} {s} = {s}.read({s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, fetch_args });
                }
            } else {
                const ct = mslReadCoordCast(m, inst.words[4]);
                // #475: Lod operand (image-operands mask bit 0x2 at words[5], value at
                // words[6]). Metal's read(uint2) defaults to mip 0; dropping the Lod
                // silently returned the base-mip texel for any texelFetch(lod>0). Pass
                // it as read(uint2(coord), lod). Checking the Lod bit (not just len>6)
                // avoids passing a lone ConstOffset's value as the lod. Matches spirv-cross.
                // #495: also check the Sample operand (mask 0x40) for multisampled textures
                // (texture2d_ms::read(uint2, sample)) — texelFetch on sampler2DMS uses Sample,
                // not Lod. Without this, the sample arg was dropped (read(uint2) wrong arity).
                if (inst.words.len > 6 and ((inst.words[5] & 0x2) != 0 or (inst.words[5] & 0x40) != 0)) {
                    try w.print("    {s} {s} = {s}.read({s}({s}), {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, ct, coord_name, names.get(inst.words[6]) orelse "0" });
                } else {
                    try w.print("    {s} {s} = {s}.read({s}({s}));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, ct, coord_name });
                }
            }
        },
        .ImageGather => {
            // textureGatherOffsets lowers to OpImageGather with the ConstOffsets
            // image operand (mask bit 0x20 at word[6], the 4-offset array id at
            // word[7]). MSL's `tex.gather(...)` takes no per-texel offset array,
            // so emitting a plain `.gather` here would SILENTLY DROP the offsets
            // (silent-wrong). Fail loudly instead; per-texel emulation (4 offset
            // gathers) is a follow-up. Likewise textureGatherOffset's single
            // ConstOffset (0x8) and any runtime Offset (0x10): the emit below
            // carries no offset (the arrayed path hardcodes int2(0)), so
            // honest-error on every offset-bearing operand (0x38 =
            // ConstOffset|Offset|ConstOffsets) rather than silent-drop.
            if (inst.words.len > 6 and (inst.words[6] & 0x38) != 0) {
                return error.UnsupportedImageOperands;
            }
            // MSL: tex.gather(samp, coord, offset, component::<swizzle>)
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            // textureGather on an ARRAY texture: split the array layer into a
            // separate integer arg, matching spirv-cross --msl exactly:
            //   2D array:   gather(s, c.xy, uint(rint(c.z)), int2(0), component::x)
            //   cube array: gather(s, c.xyz, uint(rint(c.w)), component::x)
            // (cube has no per-texel offset, so it omits the int2(0) arg).
            if (imageValueIsArrayed(m, inst.words[3])) {
                const dim = imageValueDim(m, inst.words[3]);
                const split = try mslArrayedSampleArgs(alloc, coord, dim);
                defer alloc.free(split);
                const gcomp = mslGatherComponent(m, inst.words[5]);
                if (dim == 3) {
                    try w.print("    {s} {s} = {s}.gather({s}Smplr, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, split, gcomp });
                } else {
                    try w.print("    {s} {s} = {s}.gather({s}Smplr, {s}, int2(0), {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, split, gcomp });
                }
            } else {
                // Non-arrayed: the 3rd positional arg is the OFFSET (int2), and the
                // gather channel is a trailing `component::<swizzle>` enum -- NOT the
                // bare integer index. Passing the raw component into the offset slot
                // sampled the wrong channel (silent-wrong). Matches spirv-cross
                // `gather(s, coord, int2(0), component::z)`. (#170, #470)
                const gcomp = if (inst.words.len > 5) mslGatherComponent(m, inst.words[5]) else "component::x";
                try w.print("    {s} {s} = {s}.gather({s}Smplr, {s}, int2(0), {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, gcomp });
            }
        },
        .ImageDrefGather => {
            // MSL: tex.gather_compare(samp, coord, compare)
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            try w.print("    {s} {s} = {s}.gather_compare({s}Smplr, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, si, coord, dref });
        },
        .ImageRead => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "img";
            // SubpassData (SPIR-V Dim 6 = Vulkan input attachments): the SPIR-V
            // coordinate operand is a (0,0) placeholder, because Vulkan reads a
            // subpass attachment implicitly at the current fragment position. Metal
            // has no implicit subpass read, so emit the threaded fragment coordinate
            // (`_fragCoord`, always threaded into fragment impls) instead of passing
            // (0,0) through verbatim -- otherwise every fragment samples the
            // top-left pixel. (spirv-cross does the same: read(uint2(gl_FragCoord.xy)).)
            if (imageValueDim(m, inst.words[3]) == 6) {
                // MS subpass needs texture2d_ms + a per-sample read (read(coord, sample));
                // this backend defers MS texture-type modeling, so refuse rather than emit
                // a non-MS read that would silently sample the wrong pixel/sample.
                if (imageValueIsMultisampled(m, inst.words[3])) return error.UnsupportedMultisampledSubpassInput;
                try w.print("    {s} {s} = {s}.read(uint2(_fragCoord.xy));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si });
            } else {
                const ct = mslReadCoordCast(m, inst.words[4]);
                try w.print("    {s} {s} = {s}.read({s}({s}));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, ct, names.get(inst.words[4]) orelse "0" });
            }
        },
        .ImageWrite => {
            const img = names.get(inst.words[1]) orelse "img";
            // #475: Metal texture::write(texel, uint2) requires an UNSIGNED coord; the
            // SPIR-V storage-image coord is signed int2. ImageRead casts via
            // mslReadCoordCast but ImageWrite passed it raw (asymmetry -> Metal reject).
            const ct = mslReadCoordCast(m, inst.words[2]);
            const coord = names.get(inst.words[2]) orelse "0";
            const texel = names.get(inst.words[3]) orelse "float4(0)";
            try w.print("    {s}.write({s}, {s}({s}));\n", .{ img, texel, ct, coord });
        },
        .ImageQuerySizeLod => {
            // MSL: get_width/get_height(level), get_depth(level) for 3D, and
            // get_array_size() for arrayed textures. Result rank decides how
            // many components to assemble; the image's Arrayed flag picks
            // get_array_size() vs get_depth() for the third component.
            //
            // NOTE: the emitted query EXPRESSION is correct (verified vs the
            // spirv-cross oracle), but get_depth()/get_array_size() are members
            // of texture3d/texture2d_array/texturecube_array — not the
            // texture2d<float> this backend currently hardcodes for every
            // texture (see mslTextureType / TextureDecl). Full compilation of
            // non-2D image-size queries therefore awaits the deferred,
            // backend-wide texture-type modeling.
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            const lod = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
            const rank = typeRank(m, inst.words[1]);
            if (rank >= 3) {
                if (imageValueIsArrayed(m, inst.words[3])) {
                    try w.print("    {s} {s} = {s}({s}.get_width({s}), {s}.get_height({s}), {s}.get_array_size());\n", .{ rtt, rn, rtt, img, lod, img, lod, img });
                } else {
                    try w.print("    {s} {s} = {s}({s}.get_width({s}), {s}.get_height({s}), {s}.get_depth({s}));\n", .{ rtt, rn, rtt, img, lod, img, lod, img, lod });
                }
            } else if (rank == 2) {
                try w.print("    {s} {s} = {s}({s}.get_width({s}), {s}.get_height({s}));\n", .{ rtt, rn, rtt, img, lod, img, lod });
            } else {
                try w.print("    {s} {s} = {s}.get_width({s});\n", .{ rtt, rn, img, lod });
            }
        },
        .ImageQuerySize => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            const rank = typeRank(m, inst.words[1]);
            if (rank >= 3) {
                if (imageValueIsArrayed(m, inst.words[3])) {
                    try w.print("    {s} {s} = {s}({s}.get_width(), {s}.get_height(), {s}.get_array_size());\n", .{ rtt, rn, rtt, img, img, img });
                } else {
                    try w.print("    {s} {s} = {s}({s}.get_width(), {s}.get_height(), {s}.get_depth());\n", .{ rtt, rn, rtt, img, img, img });
                }
            } else if (rank == 2) {
                try w.print("    {s} {s} = {s}({s}.get_width(), {s}.get_height());\n", .{ rtt, rn, rtt, img, img });
            } else {
                try w.print("    {s} {s} = {s}.get_width();\n", .{ rtt, rn, img });
            }
        },
        // #482: OpImageQueryLevels / OpImageQuerySamples had no emit arm (fell to
        // "unhandled op" so the result id was never defined). Metal: mip-level
        // count is texture.get_num_mip_levels(), sample count is
        // texture.get_num_samples() (the latter needs a multisampled texture type).
        // Both return uint; cast to the (int) result type.
        .ImageQueryLevels => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            try w.print("    {s} {s} = {s}({s}.get_num_mip_levels());\n", .{ rtt, rn, rtt, img });
        },
        .ImageQuerySamples => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            try w.print("    {s} {s} = {s}({s}.get_num_samples());\n", .{ rtt, rn, rtt, img });
        },
        .Kill => try w.writeAll("    discard_fragment();\n"),
        .Unreachable => {}, // no-op
        // Fragment shader interlock (SPV_EXT_fragment_shader_interlock): Metal has no
        // explicit begin/end — interlock is expressed by `[[raster_order_group(0)]]` on
        // the storage resources the fragment writes (see emitFunction's fragment path),
        // and the rasterizer serializes accesses. These ops are therefore no-ops, matching
        // spirv-cross, which emits raster_order_group and drops the ops entirely.
        .BeginInvocationInterlockEXT => {},
        .EndInvocationInterlockEXT => {},
        .ReadClockKHR => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = clock();\n", .{ rtt, names.get(inst.words[2]) orelse "t" });
        },
        // #475: fence BOTH threadgroup AND device memory so an SSBO write before the
        // barrier is visible after (mem_threadgroup alone fences only workgroup memory).
        // threadgroup_barrier takes combined flags; this is the conservative both-fence.
        .ControlBarrier => {
            try w.writeAll("    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);\n");
        },
        .MemoryBarrier => {
            try w.writeAll("    threadgroup_barrier(mem_flags::mem_device);\n");
        },
        .EmitVertex => try w.writeAll("    // EmitVertex (geometry shader)\n"),
        .EndPrimitive => try w.writeAll("    // EndPrimitive (geometry shader)\n"),
        .ImageTexelPointer => {
            // No code emission needed — the result id is resolved at each atomic call site
            // by mslAtomicObject, which detects the ImageTexelPointer op directly.
        },

        // Atomic operations → MSL atomic_fetch_*_explicit
        .AtomicIAdd => {
            const scalar = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            const obj = try mslAtomicObject(m, names, inst.words[3], scalar, alloc);
            try w.print("    {s} {s} = atomic_fetch_add_explicit({s}, {s}, memory_order_relaxed);\n", .{ scalar, rn, obj, val });
        },
        .AtomicISub => {
            const scalar = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            const obj = try mslAtomicObject(m, names, inst.words[3], scalar, alloc);
            try w.print("    {s} {s} = atomic_fetch_sub_explicit({s}, {s}, memory_order_relaxed);\n", .{ scalar, rn, obj, val });
        },
        .AtomicOr => {
            const scalar = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            const obj = try mslAtomicObject(m, names, inst.words[3], scalar, alloc);
            try w.print("    {s} {s} = atomic_fetch_or_explicit({s}, {s}, memory_order_relaxed);\n", .{ scalar, rn, obj, val });
        },
        .AtomicXor => {
            const scalar = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            const obj = try mslAtomicObject(m, names, inst.words[3], scalar, alloc);
            try w.print("    {s} {s} = atomic_fetch_xor_explicit({s}, {s}, memory_order_relaxed);\n", .{ scalar, rn, obj, val });
        },
        .AtomicAnd => {
            const scalar = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            const obj = try mslAtomicObject(m, names, inst.words[3], scalar, alloc);
            try w.print("    {s} {s} = atomic_fetch_and_explicit({s}, {s}, memory_order_relaxed);\n", .{ scalar, rn, obj, val });
        },
        .AtomicSMin, .AtomicUMin => {
            const scalar = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            const obj = try mslAtomicObject(m, names, inst.words[3], scalar, alloc);
            try w.print("    {s} {s} = atomic_fetch_min_explicit({s}, {s}, memory_order_relaxed);\n", .{ scalar, rn, obj, val });
        },
        .AtomicSMax, .AtomicUMax => {
            const scalar = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            const obj = try mslAtomicObject(m, names, inst.words[3], scalar, alloc);
            try w.print("    {s} {s} = atomic_fetch_max_explicit({s}, {s}, memory_order_relaxed);\n", .{ scalar, rn, obj, val });
        },
        .AtomicExchange => {
            const scalar = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            const obj = try mslAtomicObject(m, names, inst.words[3], scalar, alloc);
            try w.print("    {s} {s} = atomic_exchange_explicit({s}, {s}, memory_order_relaxed);\n", .{ scalar, rn, obj, val });
        },
        .AtomicCompareExchange => {
            // OpAtomicCompareExchange: result_type, result, pointer, scope, eq-sem,
            // uneq-sem, value(new/data), comparator(compare) — data=words[7], compare=words[8].
            //
            // MSL's atomic_compare_exchange_weak_explicit does NOT match GLSL atomicCompSwap:
            //  - `expected` is an in/out `thread T*` — it needs an addressable mutable
            //    lvalue, so passing `&<constant>` (e.g. `&7u`) does not compile (#263); and
            //  - it returns a bool (success), NOT the original value, whereas the SPIR-V op's
            //    result is the original loaded value.
            // Emit the spirv-cross idiom: materialize a mutable local seeded with the
            // comparator, retry on spurious _weak failure (the only CAS form MSL offers),
            // then take the original value from the local.
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 7) names.get(inst.words[7]) orelse "0" else "0";
            const cmp = if (inst.words.len > 8) names.get(inst.words[8]) orelse "0" else "0";
            const sty = try mslType(m, inst.words[1], names, alloc);
            const id = inst.words[2];
            const obj = try mslAtomicObject(m, names, inst.words[3], sty, alloc);
            try w.print("    {s} _cas_expected_{d};\n", .{ sty, id });
            try w.print("    do {{ _cas_expected_{d} = {s}; }} while (!atomic_compare_exchange_weak_explicit({s}, &_cas_expected_{d}, {s}, memory_order_relaxed, memory_order_relaxed) && _cas_expected_{d} == {s});\n", .{ id, cmp, obj, id, val, id, cmp });
            try w.print("    {s} {s} = _cas_expected_{d};\n", .{ sty, rn, id });
        },
        .AtomicFAddEXT => {
            const scalar = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0.0" else "0.0";
            const obj = try mslAtomicObject(m, names, inst.words[3], scalar, alloc);
            try w.print("    {s} {s} = atomic_fetch_add_explicit({s}, {s}, memory_order_relaxed);\n", .{ scalar, rn, obj, val });
        },

        // Subgroup operations → MSL simd_* functions
        .GroupNonUniformElect => {
            const rn = names.get(inst.words[2]) orelse "v";
            try w.print("    bool {s} = simd_is_first();\n", .{rn});
        },
        .GroupNonUniformAll => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = simd_all({s});\n", .{ rtt, rn, val });
        },
        .GroupNonUniformAny => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = simd_any({s});\n", .{ rtt, rn, val });
        },
        .GroupNonUniformAllEqual => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = simd_all({s} == simd_broadcast({s}, 0));\n", .{ rtt, rn, val, val });
        },
        .GroupNonUniformBroadcast => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const lane = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = simd_broadcast({s}, {s});\n", .{ rtt, rn, val, lane });
        },
        .GroupNonUniformBroadcastFirst => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = simd_broadcast({s}, 0);\n", .{ rtt, rn, val });
        },
        .GroupNonUniformBallot => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = simd_ballot({s});\n", .{ rtt, rn, val });
        },
        .GroupNonUniformShuffle => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const lane = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = simd_shuffle({s}, {s});\n", .{ rtt, rn, val, lane });
        },
        .GroupNonUniformShuffleXor => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const mask = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = simd_shuffle_xor({s}, {s});\n", .{ rtt, rn, val, mask });
        },
        .GroupNonUniformShuffleUp => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const delta = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = simd_shuffle_up({s}, {s});\n", .{ rtt, rn, val, delta });
        },
        .GroupNonUniformShuffleDown => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const delta = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = simd_shuffle_down({s}, {s});\n", .{ rtt, rn, val, delta });
        },
        // Subgroup ARITHMETIC ops share one lowering that honors the
        // GroupOperation literal (Reduce/InclusiveScan/ExclusiveScan/
        // ClusteredReduce); see mslEmitSubgroupArith for the operand fix.
        .GroupNonUniformIAdd, .GroupNonUniformFAdd, .GroupNonUniformIMul, .GroupNonUniformFMul, .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin, .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax, .GroupNonUniformBitwiseAnd, .GroupNonUniformBitwiseOr, .GroupNonUniformBitwiseXor, .GroupNonUniformLogicalAnd, .GroupNonUniformLogicalOr => {
            try mslEmitSubgroupArith(m, names, inst, w, alloc);
        },
        // SubgroupAllKHR / SubgroupAnyKHR (older extension equivalents)
        .SubgroupAllKHR => {
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "x";
            try w.print("    bool {s} = simd_all({s});\n", .{ rn, val });
        },
        .SubgroupAnyKHR => {
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "x";
            try w.print("    bool {s} = simd_any({s});\n", .{ rn, val });
        },
        .Return => {
            // The impl function is always `void` (fragment/vertex/compute all use the
            // void `_impl` helper + a wrapper that does `return out;`), so a bare
            // `return;` is always type-correct. It MUST be emitted for an EARLY return
            // (`if (hit) { fragColor = c; return; }`) or the early-out is lost and later
            // writes clobber it -- a silent miscompile. Previously suppressed for
            // fragments, which was only harmless for the redundant final return.
            try w.writeAll("    return;\n");
        },
        .ReturnValue => {
            const vid = inst.words[1];
            if (!(is_frag and ovid != null and vid == ovid.?)) {
                try w.print("    return {s};\n", .{names.get(vid) orelse "0"});
            }
        },
        .FunctionCall => {
            const cfid = inst.words[3];
            const cfn = names.get(cfid) orelse "func";
            const rn = names.get(inst.words[2]) orelse "v";
            const rti = inst.words[1];
            const is_void = blk: {
                const r = getDef(m, rti);
                break :blk r != null and r.?.op == .TypeVoid;
            };
            if (is_void) {
                try w.print("    {s}(", .{cfn});
            } else {
                const rtt = mslValueType(m, inst.words[1], names, alloc) catch try mslType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s} = {s}(", .{ rtt, rn, cfn });
            }
            var first_arg = true;
            for (inst.words[4..]) |aid| {
                if (!first_arg) try w.writeAll(", ");
                first_arg = false;
                try w.writeAll(names.get(aid) orelse "0");
            }
            // Pass cbuffer and texture/sampler args to function calls
            // (all non-entry functions now have these as extra params)
            for (cbuffers.items) |cb| {
                if (!first_arg) try w.writeAll(", ");
                first_arg = false;
                try w.print("{s}_1", .{cb.name});
            }
            // Pass SSBO args to function calls (all non-entry functions now have these)
            for (storage_buffers.items) |sb| {
                if (!first_arg) try w.writeAll(", ");
                first_arg = false;
                try w.print("{s}", .{sb.name});
            }
            for (textures.items) |tex| {
                if (!first_arg) try w.writeAll(", ");
                first_arg = false;
                try w.print("{s}", .{tex.name});
                if (!tex.is_storage) try w.print(", {s}Smplr", .{tex.name});
            }
            // #476: pass the stage-in struct through to the callee (every non-entry
            // fragment function receives `main0_in in` when there are varyings).
            // `in` is always in scope here: the entry impl takes it as a param and
            // each non-entry function re-threads it, so nested calls stay valid.
            if (g_has_stage_in) {
                if (!first_arg) try w.writeAll(", ");
                first_arg = false;
                try w.writeAll("in");
            }
            // #489: pass the fragment output (matches the helper's threaded output param).
            // #472: multi-output passes every output by name (each is in scope as the
            // caller's own threaded param / the entry's main0_out field).
            if (g_frag_outputs) |list| {
                for (list) |fo| {
                    if (!first_arg) try w.writeAll(", ");
                    first_arg = false;
                    try w.writeAll(fo.name);
                }
            } else if (g_frag_out_name) |oname| {
                if (!first_arg) try w.writeAll(", ");
                first_arg = false;
                try w.writeAll(oname);
            }
            // #489: pass gl_FragCoord (_fragCoord) -- matches the helper's threaded param.
            if (g_frag_coord_ty != null) {
                if (!first_arg) try w.writeAll(", ");
                first_arg = false;
                try w.writeAll("_fragCoord");
            }
            // Matches the helper's threaded Private-global params. Each name is in
            // scope here: the entry impl declares it, every helper re-threads it.
            if (g_priv_globals) |list| {
                for (list) |pg| {
                    if (!first_arg) try w.writeAll(", ");
                    first_arg = false;
                    try w.writeAll(pg.name);
                }
            }
            try w.writeAll(");\n");
        },
        .SetMeshOutputsEXT => {
            if (inst.words.len >= 3) {
                const vc = idToExprMsl(m, names, inst.words[1], alloc);
                const pc = idToExprMsl(m, names, inst.words[2], alloc);
                try w.print("    mf.set_count({s}, {s});\n", .{ vc, pc });
            }
        },
        .EmitMeshTasksEXT => {
            if (inst.words.len >= 5) {
                const x = idToExprMsl(m, names, inst.words[1], alloc);
                const y = idToExprMsl(m, names, inst.words[2], alloc);
                const z = idToExprMsl(m, names, inst.words[3], alloc);
                try w.print("    dispatch_mesh_threadgroups(mesh_grid, {s}, {s}, {s});\n", .{ x, y, z });
            }
        },
        // Runtime SSBO array `.length()` (OpArrayLength). MSL has no buffer-length query;
        // spirv-cross passes a host-provided `spvBufferSizeConstants` array and computes
        // `(bufferByteSize - memberOffset) / elementStride`. The structure operand's slot in
        // that array is `arraylen_buf_index` (built only on the supported compute/non-argbuf/
        // no-atomic path); absent → honest-error (no silent-wrong undeclared identifier).
        .ArrayLength => {
            if (inst.words.len < 5) return error.UnsupportedOp;
            const struct_ptr = inst.words[3];
            const member_idx = inst.words[4];
            const size_idx = arraylen_buf_index.get(struct_ptr) orelse return error.UnsupportedOp;
            const var_def = getDef(m, struct_ptr) orelse return error.UnsupportedOp;
            if (var_def.op != .Variable or var_def.words.len < 4) return error.UnsupportedOp;
            const ptr_def = getDef(m, var_def.words[1]) orelse return error.UnsupportedOp;
            if (ptr_def.op != .TypePointer or ptr_def.words.len < 4) return error.UnsupportedOp;
            const struct_id = ptr_def.words[3];
            const struct_inst = getDef(m, struct_id) orelse return error.UnsupportedOp;
            if (struct_inst.op != .TypeStruct or struct_inst.words.len < 3 + @as(usize, member_idx)) return error.UnsupportedOp;
            const member_type = struct_inst.words[2 + @as(usize, member_idx)];
            const mt_def = getDef(m, member_type) orelse return error.UnsupportedOp;
            if (mt_def.op != .TypeRuntimeArray) return error.UnsupportedOp;
            const stride = arrayStrideOf(m, member_type) orelse return error.UnsupportedOp;
            // Member byte offset (OpMemberDecorate <struct> <member> Offset N); default 0.
            var offset: u32 = 0;
            for (m.instructions) |di| {
                if (di.op == .MemberDecorate and di.words.len >= 5 and
                    di.words[1] == struct_id and di.words[2] == member_idx)
                {
                    const dec: spirv.Decoration = @enumFromInt(di.words[3]);
                    if (dec == .offset) {
                        offset = di.words[4];
                        break;
                    }
                }
            }
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            try w.print("    {s} {s} = (spvBufferSizeConstants[{d}] - {d}) / {d};\n", .{ rtt, rn, size_idx, offset, stride });
        },

        else => {
            // Unhandled opcode. If it produces a result id the module references, that
            // result would be an undeclared identifier (silent-wrong at exit 0) -- fail
            // loud instead (the wedge). If the result is unused (or there is no result),
            // keep the visible stub comment: it is harmless and several shaders
            // (e.g. block-match filter ops) legitimately reach here with an unused result.
            if (inst.words.len >= 3) {
                const rid = inst.words[2];
                var uses: u32 = 0;
                for (m.instructions) |u| {
                    for (u.words) |wd| if (wd == rid) {
                        uses += 1;
                    };
                }
                if (uses > 1) return error.UnsupportedOpcode;
            }
            try w.print("    // unhandled op {d}\n", .{@intFromEnum(inst.op)});
        },
    }
}
/// #170: OpSMod (floored signed modulo, sign of the DIVISOR) as `((x % y) + y) % y`. Metal
/// `%` is truncated (sign of the dividend = OpSRem); this compound turns it floored for every
/// sign combination. Componentwise. Equivalent to spirv-cross's spvSMod helper.
fn emitSMod(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try mslType(m, inst.words[1], names, alloc);
    const x = names.get(inst.words[3]) orelse "a";
    const y = names.get(inst.words[4]) orelse "b";
    try w.print("    {s} {s} = (({s} % {s}) + {s}) % {s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", x, y, y, y });
}
/// Classify an atomic pointer: SSBO variable or ImageTexelPointer (image atomic)
// The MSL address space an atomic pointer lives in, derived from the SPIR-V storage
// class of the pointer's type. `shared` (Workgroup) → threadgroup; SSBO (StorageBuffer /
// Uniform) → device. Metal's atomic_*_explicit builtins require an address-space-qualified
// `atomic_T*`, so this qualifier is mandatory at the call site.
fn mslAtomicAddrSpace(m: *const ParsedModule, ptr_id: u32) []const u8 {
    const pd = getDef(m, ptr_id) orelse return "device";
    if (pd.words.len < 2) return "device";
    const tptr = getDef(m, pd.words[1]) orelse return "device";
    // OpTypePointer: [1]=result id, [2]=storage class, [3]=pointee type.
    if (tptr.op == .TypePointer and tptr.words.len > 2) {
        const sc: spirv.StorageClass = @enumFromInt(tptr.words[2]);
        // Only Workgroup (`shared`) and StorageBuffer/Uniform (SSBO) can be atomic
        // targets; the former maps to threadgroup, everything else to device.
        return if (sc == .Workgroup) "threadgroup" else "device";
    }
    return "device";
}

// MSL atomic type name for a scalar MSL type. Note: `atomic_float` requires Metal 3.0
// (only reachable via the GL_EXT_shader_atomic_float `AtomicFAddEXT` path); `half`/f16
// atomics do not exist in the GLSL frontend, so the catch-all `atomic_uint` is never
// actually hit for a half scalar.
fn mslAtomicTypeName(scalar: []const u8) []const u8 {
    if (std.mem.eql(u8, scalar, "int")) return "atomic_int";
    if (std.mem.eql(u8, scalar, "float")) return "atomic_float"; // Metal 3.0+
    return "atomic_uint";
}

// The object expression for an MSL atomic_*_explicit call. For an image atomic
// (OpImageTexelPointer) this is the buffer-backed linearized form
// `(device atomic_T*)&<img>_atomic[spvImage2DAtomicCoord(coord, <img>)]` (#267); for an
// SSBO/shared scalar it is the spirv-cross-faithful `(device|threadgroup atomic_T*)&<member>` — a plain scalar
// member is NOT an atomic pointer, so the cast is required to compile.
fn mslAtomicObject(m: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), ptr_id: u32, scalar: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    if (getDef(m, ptr_id)) |d| {
        if (d.op == .ImageTexelPointer) {
            // Storage-image atomic (#267): Metal has no read-write atomic on a texture2d,
            // so target a buffer-backed linear texture — a separate `device atomic_T*
            // <img>_atomic` buffer indexed by the linearized coordinate. Matches
            // spirv-cross: `(device atomic_uint*)&img_atomic[spvImage2DAtomicCoord(coord, img)]`.
            // (Non-2D/arrayed/float images and the fragment/vertex/argbuf paths were
            // honest-errored in spirvToMSL, so this is only reached for the supported case.)
            const img = names.get(d.words[3]) orelse "img";
            const coord = names.get(d.words[4]) orelse "0";
            return std.fmt.allocPrint(alloc, "(device {s}*)&{s}_atomic[spvImage2DAtomicCoord({s}, {s})]", .{ mslAtomicTypeName(scalar), img, coord, img });
        }
    }
    const ptr = names.get(ptr_id) orelse "mem";
    return std.fmt.allocPrint(alloc, "({s} {s}*)&{s}", .{ mslAtomicAddrSpace(m, ptr_id), mslAtomicTypeName(scalar), ptr });
}

fn emitStd450(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, instruction: u32, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try mslType(m, inst.words[1], names, alloc);
    // #488: Metal's reflect/refract/normalize are VECTOR-only -- a SCALAR call is
    // ambiguous. Lower scalar reflect/refract to the formula, scalar normalize to
    // v/abs(v); vector forms stay as the intrinsics.
    if (instruction == 69) {
        if (getDef(m, inst.words[1])) |rty| {
            if (rty.op == .TypeFloat) {
                const v = names.get(inst.words[5]) orelse "x";
                const rn = names.get(inst.words[2]) orelse "v";
                try w.print("    {s} {s} = {s} / abs({s});\n", .{ rtt, rn, v, v });
                return;
            }
        }
    }
    // #488: Metal's length/distance are VECTOR-only -- a SCALAR call is ambiguous.
    // Lower scalar length(v) -> abs(v), distance(a,b) -> abs(a-b). length/distance
    // return float for BOTH scalar and vector operands, so the RESULT type can't
    // distinguish them -- check the OPERAND type instead. Vector forms stay as the
    // intrinsics.
    if (instruction == 66 or instruction == 67) {
        const operand_is_scalar = blk: {
            const oty = common.getTypeOf(m, inst.words[5]) orelse break :blk false;
            const oi = getDef(m, oty) orelse break :blk false;
            break :blk oi.op == .TypeFloat;
        };
        if (operand_is_scalar) {
            const rn = names.get(inst.words[2]) orelse "v";
            if (instruction == 66) {
                const v = names.get(inst.words[5]) orelse "x";
                try w.print("    {s} {s} = abs({s});\n", .{ rtt, rn, v });
            } else {
                const a = names.get(inst.words[5]) orelse "x";
                const b = names.get(inst.words[6]) orelse "y";
                try w.print("    {s} {s} = abs({s} - {s});\n", .{ rtt, rn, a, b });
            }
            return;
        }
    }
    if (instruction == 71 or instruction == 72) {
        if (getDef(m, inst.words[1])) |rty| {
            if (rty.op == .TypeFloat) {
                const I = names.get(inst.words[5]) orelse "x";
                const N = names.get(inst.words[6]) orelse "y";
                const rn = names.get(inst.words[2]) orelse "v";
                if (instruction == 71) {
                    // reflect(I,N) = I - 2*dot(N,I)*N  (scalar dot = N*I)
                    try w.print("    {s} {s} = {s} - (2.0 * ({s} * {s}) * {s});\n", .{ rtt, rn, I, N, I, N });
                } else if (inst.words.len >= 8) {
                    // refract(I,N,eta): k=1-eta²(1-(N·I)²); k>=0 ? eta*I-(eta*(N·I)+sqrt(k))*N : 0
                    const e = names.get(inst.words[7]) orelse "z";
                    const d = try std.fmt.allocPrint(alloc, "({s} * {s})", .{ N, I });
                    const k = try std.fmt.allocPrint(alloc, "(1.0 - ({s} * {s}) * (1.0 - ({s}) * ({s})))", .{ e, e, d, d });
                    try w.print("    {s} {s} = (({s}) >= 0.0) ? (({s} * {s}) - ((({s} * ({s})) + sqrt({s})) * {s})) : 0.0;\n", .{ rtt, rn, k, e, I, e, d, k, N });
                }
                return;
            }
        }
    }
    // #472: Modf (opcode 35) — the 2-operand pointer form `modf(x, &ip)` (GLSL
    // `modf(x, out ip)`). Metal's `modf(x, thread T& intval)` cannot bind a non-const
    // reference to a vector element or any sub-object lvalue ("non-const reference
    // cannot bind to vector element"); only a whole thread variable binds. When the
    // resolved pointer operand is not a plain identifier (e.g. `v.x`, `arr[i]`),
    // lower through a temp scalar and store back — matching spirv-cross. The temp's
    // type is the result (fract) type, which equals the pointed-to element type.
    if (instruction == 35 and inst.words.len >= 7) {
        const rn = names.get(inst.words[2]) orelse "v";
        const x = names.get(inst.words[5]) orelse "x";
        const ptr_name = names.get(inst.words[6]) orelse "p";
        if (std.mem.indexOfAny(u8, ptr_name, ".[") == null) {
            try w.print("    {s} {s} = modf({s}, {s});\n", .{ rtt, rn, x, ptr_name });
        } else {
            const id = inst.words[2];
            try w.print("    {s} _modf_ip_{d};\n", .{ rtt, id });
            try w.print("    {s} {s} = modf({s}, _modf_ip_{d});\n", .{ rtt, rn, x, id });
            try w.print("    {s} = _modf_ip_{d};\n", .{ ptr_name, id });
        }
        return;
    }
    const func = std450ToMsl(instruction) orelse {
        try w.print("    // unhandled std450 #{d}\n", .{instruction});
        return;
    };
    try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", func });
    for (inst.words[5..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\n");
}

fn idToExprMsl(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), id: u32, alloc: std.mem.Allocator) []const u8 {
    if (names.get(id)) |name| return name;
    const def = getDef(m, id) orelse return "0";
    if (def.op == .Constant and def.words.len > 3) {
        return std.fmt.allocPrint(alloc, "{d}", .{def.words[3]}) catch "0";
    }
    if (def.op == .ConstantTrue) return "true";
    if (def.op == .ConstantFalse) return "false";
    return "0";
}
