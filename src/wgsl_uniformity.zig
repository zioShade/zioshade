// SPDX-License-Identifier: MIT OR Apache-2.0
//! The WGSL uniformity prepass (#wgsl-uniformity-8k2): which implicit-Lod
//! samples (and, since #685, which derivative instructions) sit in non-uniform
//! control flow.
//!
//! Extracted from spirv_to_wgsl.zig (issue #691) with its behavior unchanged:
//! the consumer is that file's emitter, which lowers every marked sample to
//! the uniformity-safe explicit-Level form and refuses every marked derivative.
//!
//! #wgsl-uniformity-8k2: which implicit-Lod samples (and, since #685, which
//! derivative instructions) sit in non-uniform flow
//!
//! WGSL gates the implicit-Lod sampling builtins (textureSample,
//! textureSampleBias, textureSampleCompare and the proj-lowered forms of the
//! three) on UNIFORM CONTROL FLOW: tint (Chrome/Dawn) and naga reject a module
//! where the call runs after flow has diverged. The classic shape is a shader
//! that early-returns inside a conditional and then samples: every text gate
//! and the naga round-trip proxy were green while the wintty player rendered
//! black, because only the consumer stack (the browser oracle) runs the real
//! uniformity analysis (bead zioshade-8k2).
//!
//! The lowering mirrors what SPIRV-Cross does whenever an implicit-Lod form is
//! not available in the target: pin the level to 0 (its MSL backend promotes a
//! constant-zero gradient on sample_compare to `level(0)`). For the Bias
//! operand there is no uniformity-safe WGSL form at all: WGSL has no
//! textureQueryLod to fold a bias into an explicit level, and SPIRV-Cross's
//! own MSL path likewise only DROPS a bias it cannot express (constant-zero
//! bias on sample_compare is dropped outright there). So the bias is dropped
//! and the level pinned to 0 rather than honest-erroring the whole shader,
//! which would resurrect the black-player failure mode this class caused.
//!
//! WHICH samples get downgraded is decided by this module's analysis, built to
//! mirror what tint actually accepts. Every rule was probed on Chrome for
//! Testing through tools/wgsl_browser_check.mjs with hand-written WGSL
//! overrides; those probes are COMMITTED as tools/wgsl_uniformity_probes/
//! (issue #691), each pNN_name.wgsl a self-contained module whose tint
//! verdict is the evidence, so the basis is re-runnable: the
//! wgsl-uniformity-probes just recipe sweeps them through the same oracle and
//! fails on a verdict flip in EITHER direction. Probe names are cited at each
//! rule below; the verdicts of the committed corpus are:
//!   tint REJECTS: p02_nonuniform_if, p03_early_return_one_arm (reconstructed
//!     2026-08-25 from the rule text; the original probing session's file was
//!     lost, and modern tint rejects the reconstruction exactly as recorded),
//!     p09_varying_bound_loop, p12_helper_in_nonuniform_if,
//!     p13_cond_break_loop, p14_switch_nonuniform, p17_phi_of_consts,
//!     p22_indexed_uniform_read, p23b_param_nonuniform
//!   tint ACCEPTS: p01_control, p04_uniform_if, p05_uniform_early_return,
//!     p07_const_loop, p08_uniform_bound_loop, p10_empty_if_join,
//!     p11_helper_toplevel, p18_after_varying_loop, p20_discard,
//!     p21_after_nonuniform_switch, p23a_param_uniform, p24_phi_uniform_edge
//!   * flow(B) = OR over the contributions of B's incoming edges (a block is
//!     uniform when some edge delivers the FULL invocation set, either
//!     directly or by reconverging every path that diverged):
//!       - P ends in OpBranch: flow(P)
//!       - P ends in OpBranchConditional/OpSwitch on a UNIFORM value: flow(P)
//!       - P ends in OpBranchConditional/OpSwitch on a NON-uniform value:
//!         the region's entry flow if B postdominates P, else non-uniform.
//!         Postdominance is what keeps a MERGE where every path reconverges
//!         uniform (probe p10: an `if (nonuniform) { ... }` whose arms
//!         complete keeps the following sample implicit), while a merge
//!         reached by a SUBSET is non-uniform (probe p03: early return in
//!         one arm; p13: conditional break; p09: varying-bound loop body).
//!       - loop-prelude blocks (the header chain up to the trip-count
//!         conditional, plus the continue block) execute once PER ITERATION,
//!         so their flow is the loop's entry flow gated by the uniformity of
//!         the trip-count conditions (probe p07/p09).
//!   * OpKill is NOT an exit for postdominance (probe p20: a discard does not
//!     poison the following flow; the invocation keeps executing statements).
//!   * value seeds: constants, and loads through pointers rooted at a variable
//!     THIS BACKEND EMITS AS `var<uniform>` OR READ-ONLY `var<storage>`, whose
//!     dynamic indices are uniform (probe p04: a member read is uniform; p22: a
//!     NON-uniform index into a uniform array is not). The predicate is the
//!     emitted ADDRESS SPACE, not the SPIR-V storage class: glslang targeting
//!     Vulkan 1.0 puts an SSBO in StorageClass Uniform (BufferBlock on the
//!     struct) and from Vulkan 1.1 in StorageClass StorageBuffer, and WGSL
//!     calls a read_write storage read NON-uniform and a read-only one uniform.
//!     See readIsUniformStorage.
//!   * values propagate through pure ops; a phi is uniform only when every
//!     incoming value is uniform AND every incoming edge left its block on a
//!     uniform branch (probe p17: a phi of constants across a non-uniform if
//!     is non-uniform; p24: across a uniform if it stays uniform).
//!   * a store into a FUNCTION-scope variable reaches only the loads its block
//!     can actually flow to (#684): the store rule is FLOW-SENSITIVE within
//!     one function, on the successor graph with loop back edges included, so
//!     a store later in a loop body still poisons an earlier load on the next
//!     iteration while a store AFTER a load it can no longer reach does not
//!     poison it. tint's local-variable uniformity is flow-sensitive the same
//!     way. Module-scope Private/Output roots keep the flow-insensitive rule
//!     (see the imprecision list below for why).
//!   * helper functions inherit the flow of their CALL SITES (probe p11/p12)
//!     and a parameter is a uniform value iff every call site passes a
//!     uniform argument (probe p23a/p23b). Both are interprocedural and
//!     resolved by the same downward fixpoint.
//!   * a function-call RESULT is uniform iff every OpReturnValue of the callee
//!     returns a uniform value from a block with uniform flow (#684; probed:
//!     a uniform value returned from a diverged arm is NON-uniform, the same
//!     selection rule as a phi edge, while a return after a reconverged if or
//!     selected by a uniform condition stays uniform). This is a third
//!     interprocedural component of the same downward fixpoint.
//! The analysis is deliberately conservative where it cannot model tint
//! exactly (pointer PARAMETERS are never uniform VALUES; loads through them
//! are judged from the call sites instead).
//!
//! WHAT THIS DOES NOT COVER. An earlier version of this comment claimed the
//! analysis "never claims uniformity the probes showed tint rejecting, so the
//! emitted module can only be MORE accepted, never less". That was FALSE and is
//! retracted. It was wrong on its own terms once (the value seed keyed off the
//! SPIR-V storage class, so a Vulkan-1.0 SSBO read counted as uniform, the
//! implicit sample was kept, and tint rejected the module; fixed above by
//! readIsUniformStorage), and the claim is not something the analysis can
//! promise in general: it is a heuristic mirror of tint's rules, not tint.
//! Known imprecisions in the SAFE direction, all silent MIP CHANGES rather
//! than rejects, are left standing on purpose:
//!   * the #684 store-reachability filter applies ONLY to stores in the SAME
//!     function as the load, only when that function is not on a call-graph
//!     cycle, and only when the variable itself is FUNCTION-scope: the filter
//!     argues about ONE invocation, and only a Function-scope variable's
//!     contents live and die with one. A module-scope Private or Output root
//!     persists across SEQUENTIAL calls of the same function (a store by an
//!     earlier call can feed a load of a later one from an unreachable block;
//!     the #684 review repro), so for those, for stores made in a DIFFERENT
//!     function, and for cyclic functions, every store counts unconditionally.
//!     Stores a callee makes through a pointer parameter are likewise judged
//!     per PARAMETER (every store through it uniform), not per reaching store
//!     site within the callee.
//!   * the #684 return rule consults the callee's flow, whose entry is the
//!     AND of its call sites: a helper with ONE non-uniform call site has
//!     every block poisoned, so its result is called non-uniform even at its
//!     uniform call sites where tint would keep it (and where a same-shaped
//!     phi of the returned values would stay uniform). Functions on a
//!     call-graph cycle keep the pre-#684 verdict outright: their result is
//!     never called uniform.
//!
//! The DERIVATIVE half of the same WGSL rule was once a knowingly-open gap in
//! the UNSAFE direction here and is IN SCOPE since #685
//! (#wgsl-uniformity-8k2-derivatives): WGSL gates dpdx/dpdxCoarse/dpdxFine and
//! the dpdy/fwidth families on uniform control flow exactly as it gates
//! textureSample, so this prepass ALSO marks the nine derivative opcodes that
//! sit in non-uniform flow, on the same flow verdict the samples use. But
//! where a marked sample is LOWERED (the explicit-Level pin), a marked
//! derivative is REFUSED at emission: WGSL has no explicit-derivative form to
//! pin anything to, so there is no downgrade path and the honest error naming
//! the hoist workaround is the only correct move (see
//! recordUnsupportedNonuniformDerivative and the derivative arms in emitBody).
//! Both imprecisions listed above still apply to that marking in the SAFE
//! direction: a wrongly-marked derivative refuses a shader tint would have
//! accepted, never the reverse.

const std = @import("std");
const spirv = @import("spirv.zig");
const common = @import("spirv_cross_common.zig");

const ParsedModule = common.ParsedModule;
const DecorationEntry = common.DecorationEntry;

// Shared cross-compiler helpers (moved to spirv_cross_common.zig with this
// module's extraction, issue #691): value-less decoration query and
// array-of-arrays unwrap.
const hasDec = common.hasDec;
const arrayElementType = common.arrayElementType;

// ─────────────────────────────────────────────────────────────────────────
// public surface

/// The failure vocabulary of this module, written out rather than inferred.
pub const Error = error{
    OutOfMemory,
    /// The internal-invariant failure: the fixpoint below only moves DOWN, so
    /// a module that has not settled after `max_rounds` rounds means an
    /// invariant broke in zioshade. This is the ONLY non-OOM failure the
    /// prepass can produce, which is what the cli.zig detail gate relies on.
    UniformityAnalysisDidNotConverge,
};

/// Fixpoint round cap (see the entry point for why failing loud there is the
/// honest trade). pub so the backend records the same number in its
/// last_error_detail message.
pub const max_rounds: u32 = 1000;

/// OpTerminateInvocation = 4416, SPIR-V 1.6's replacement for OpKill (and the
/// SPV_KHR_terminate_invocation form every recent glslang emits for `discard`
/// when targeting 1.6). `spirv.Op` is non-exhaustive and does NOT name it, so
/// it has to be matched by raw opcode number. It is a DISCARD-LIKE BLOCK
/// TERMINATOR, which is what the uniformity prepass cares about: see the
/// classification note in `UniformityAnalysis.parse`.
fn isTerminateInvocation(op: spirv.Op) bool {
    return @intFromEnum(op) == 4416;
}

/// Terminator classification for one CFG block of the uniformity walk.
const UniTerm = union(enum) {
    branch: u32,
    cond: struct { cond: u32, t: u32, f: u32 },
    swit: struct { sel: u32, targets: []const u32 },
    ret,
    kill,
    unreach,
};

const UniBlock = struct {
    label: u32,
    term: UniTerm,
    /// successor block indices (resolved once the whole function is parsed)
    succs: []const usize,
    /// predecessor block indices (resolved once the whole function is parsed)
    preds: []const usize = &.{},
    flow: bool = true,
};

/// One OpFunctionCall site: the callee, the block the call sits in, and the
/// argument ids (a parameter is uniform iff every site passes a uniform arg).
const UniCall = struct { callee: u32, block: usize, args: []const u32 };

/// One implicit-Lod sample instruction: its result id (the key the emitter
/// consults) and the block it sits in. The same record shape carries the
/// DERIVATIVE instructions (see UniFunc.derivatives): result id plus block is
/// all either consumer needs.
const UniSample = struct { result: u32, block: usize };

/// One OpStore into a function/output-scope variable: what was stored, and
/// the block the store sits in (glslang lowers locals and loop counters to
/// variables, not phis, so uniform values flow through stores).
const UniStore = struct { root: u32, val: u32, func: usize, block: usize };

/// One OpStore THROUGH a pointer parameter (glslang's ABI passes every GLSL
/// parameter as ptr<function, T>, so helper reads of a parameter are loads
/// through the pointer the caller synthesized around its argument local).
const UniParamStore = struct { func: usize, param: usize, val: u32, block: usize };

/// One call argument that is a pointer to a variable: parameter position `pos`
/// of `callee` receives (a chain rooted at) `root`. Ties the callee's loads
/// through that parameter to the caller's stores into the variable. The call
/// site (`caller`, `block`) is what the #684 reachability filter consults: a
/// callee store through this pointer only matters to a load the CALL can feed.
const UniArgVar = struct { callee: u32, pos: usize, root: u32, caller: usize, block: usize };

/// One OpReturnValue: the value returned and the block it returns from. The
/// block is load-bearing (#684): tint judges a return from a DIVERGED arm
/// non-uniform even when the returned value is uniform (probed; the same
/// selection rule as a phi edge), so the return rule needs WHERE, not just
/// WHAT.
const UniReturn = struct { val: u32, block: usize };

/// WHERE a load sits (function index + block index). The #684 store rule
/// counts only stores whose block can REACH this point; null means "location
/// unknown" and disables the filter (every store counts, the conservative
/// pre-#684 verdict).
const UniLoc = struct { func: usize, block: usize };

/// One structured loop: the header block (where OpLoopMerge sits), the
/// continue block, the prelude blocks (header chain up to the conditional
/// that governs the trip count, plus the continue block itself) and the
/// conditions governing that trip count. Statements in the prelude execute
/// once PER ITERATION, so their flow is gated by the trip count's
/// uniformity, not just by the loop entry's flow.
const UniLoop = struct {
    header: usize,
    continue_block: ?usize,
    prelude: []const usize,
    governing: []const u32,
};

const UniFunc = struct {
    id: u32,
    params: []const u32,
    blocks: []UniBlock,
    entry_block: usize,
    calls: []const UniCall,
    samples: []const UniSample,
    returns: []const UniReturn,
    /// the derivative instructions of this function (#685): unlike samples
    /// they have no uniformity-safe lowered form, so the emitter REFUSES them
    derivatives: []const UniSample,
    is_entry_point: bool,
    /// fixpoint variables: only ever move DOWN from true
    entry_flow: bool = true,
    param_uniform: []bool,
    /// (#684) fixpoint variable: this function's RESULT is a uniform value
    returns_uniform: bool = true,
};

const UniformityAnalysis = struct {
    module: *const ParsedModule,
    /// the module's decorations, needed to tell a real UBO and a READ-ONLY
    /// storage buffer (both uniform reads) from a read_write one (not)
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    arena: std.mem.Allocator,
    funcs: []UniFunc,
    func_by_id: std.AutoHashMap(u32, usize),
    label_to_block: []std.AutoHashMap(u32, usize),
    /// result id -> owning function index (phi/parameter classification)
    owner_func: std.AutoHashMap(u32, usize),
    /// result id -> block index within its owning function. The #684 store
    /// rule needs WHERE a load sits, not just which function owns it.
    block_of: std.AutoHashMap(u32, usize),
    /// parameter result id -> parameter index in its function
    param_index: std.AutoHashMap(u32, usize),
    /// ids currently believed to hold UNIFORM VALUES (downward fixpoint)
    values: std.AutoHashMap(u32, void),
    /// every OpStore into a function/output-scope variable, as ONE FLAT LIST
    /// (an earlier version of this comment claimed they were grouped by root
    /// variable; they never were). varStoresUniform LINEARLY SCANS the whole
    /// list on every call and every fixpoint round, so a query costs
    /// O(all stores), not O(stores into this root). Grouping by root is the
    /// obvious win if this ever shows up in a profile; nothing measured has.
    stores: std.ArrayListUnmanaged(UniStore) = .empty,
    /// all OpStores through a pointer parameter (flat, scanned like `stores`)
    param_stores: std.ArrayListUnmanaged(UniParamStore) = .empty,
    /// call arguments that are pointers to variables (flat, scanned likewise)
    arg_vars: std.ArrayListUnmanaged(UniArgVar) = .empty,
    /// (function, param index) whose argument pointer could not be resolved
    /// to a variable (forwarded pointer params, opaque aliasing)
    opaque_params: std.AutoHashMap(u64, void),
    /// (function, block) -> loop header block, for every prelude block.
    /// SINGLE-VALUED, and the write loop in `parse` is last-write-wins; that
    /// is a deliberate policy, not an accident (issue #691 asked for one of
    /// the two). A block CAN sit in two loops' prelude chains: an outer
    /// `for (;;)` whose header branches straight into a nested loop's header
    /// puts that header in the outer chain (the chain walk stops at the inner
    /// trip-count conditional) and in the inner chain too, and that shape is
    /// reachable from ordinary glslang output, so asserting no collision would
    /// reject shaders glslang legitimately produces. Which loop wins follows
    /// parse order, which follows block layout: in structured layouts the
    /// outer loop's OpLoopMerge precedes the inner's, so the INNER loop wins,
    /// and that resolution is the correct-or-conservative one -- the losing
    /// outer loop's gating still reaches the block, because the outer header
    /// is itself a prelude block whose flow loopEntryFlow's pred walk
    /// consults. A module with an unstructured block layout could lay the
    /// inner loop's blocks out first and resolve the collision to the OUTER
    /// loop, judging the block by the outer trip count where tint judges it
    /// by the inner's; that corner belongs to the imprecision accounting in
    /// the module doc, not to an assert.
    prelude_of: std.AutoHashMap(u64, u64),
    /// function index -> its loops
    loops_of: []std.ArrayListUnmanaged(UniLoop),
    /// raw OpLoopMerge records (header block LABEL -> merge/continue labels),
    /// resolved into UniLoop prelude/governing data once the function is
    /// parsed; label ids are globally unique, block indices are not
    loop_merges: std.AutoHashMap(u32, UniLoopMerge),
    /// per-function transitive block-reachability rows, computed LAZILY on
    /// first query (#684): rows[from][to] says some CFG path leads from block
    /// `from` to block `to`. Built from the RAW successor graph (loop back
    /// edges included), because the store rule is a MAY-WRITE filter: a store
    /// later in a loop body still feeds a load earlier in the same loop on the
    /// next iteration. The diagonal is true: within one block the store/load
    /// order is not modelled, so a store in the load's own block counts.
    reach_rows: []?[]const []const bool = &.{},
    /// functions that can reach THEMSELVES through at least one call edge
    /// (self-recursion or a cycle, #684). Both #684 rules need one invocation
    /// to be the only relevant one: same-function store reachability and
    /// return-value uniformity are only sound for functions that cannot be on
    /// the stack twice, so cyclic functions keep the pre-#684 conservative
    /// verdicts (count every store, never a uniform result).
    recursive_funcs: []const bool = &.{},
    /// scratch (reused, arena-backed): postdominance DFS
    visited: std.AutoHashMap(usize, void),
    dfs_stack: std.ArrayListUnmanaged(usize) = .empty,

    /// Recursion cap shared by EVERY recursive helper in this struct: the
    /// pointer/index walks (pointerRoot, pointerParamOf, chainIndicesUniform)
    /// and the regionEntry -> loopEntryFlow -> edgeContribution cycle.
    ///
    /// The flow cycle is NOT self-terminating on arbitrary SPIR-V: a loop
    /// header with a second back edge from one of its own PRELUDE blocks (a
    /// prelude block whose non-uniform conditional targets the header on both
    /// arms) sends regionEntry(prelude) -> loopEntryFlow(header) ->
    /// edgeContribution(prelude, header) -> regionEntry(prelude) round forever
    /// and blows the stack. spirv-val rejects that module, but the CTS and
    /// external-ingestion paths feed non-glslang SPIR-V and the other three
    /// backends honest-error on it, so a SIGSEGV here is a mandate violation.
    /// Hitting the cap yields NON-uniform / no-root, the conservative
    /// direction: the sample is downgraded, never wrongly kept implicit.
    const max_flow_depth: u32 = 64;

    /// Walk a pointer chain to its root OpVariable id (null when the chain
    /// bottoms out at a parameter or an unknown op).
    fn pointerRoot(a: *UniformityAnalysis, ptr_id: u32, depth: u32) ?u32 {
        if (depth > max_flow_depth) return null;
        const inst = common.getDef(a.module, ptr_id) orelse return null;
        return switch (inst.op) {
            .Variable => ptr_id,
            // getDef only guarantees words.len >= 3 (the instruction defines an
            // id); a TRUNCATED chain op would index past the end. Non-glslang
            // SPIR-V reaches this walk, so answer "unknown root" rather than
            // panic.
            .AccessChain, .CopyObject => if (inst.words.len > 3) a.pointerRoot(inst.words[3], depth + 1) else null,
            else => null,
        };
    }

    /// If `ptr_id` bottoms out at one of `params` (this function's pointer
    /// parameters), return its index; null otherwise. glslang passes every
    /// GLSL parameter this way, so loads/stores through parameters are the
    /// COMMON shape for helper functions, not an exotic one.
    fn pointerParamOf(a: *UniformityAnalysis, params: []const u32, ptr_id: u32, depth: u32) ?usize {
        if (depth > max_flow_depth) return null;
        const inst = common.getDef(a.module, ptr_id) orelse return null;
        switch (inst.op) {
            // truncated chain op: unknown parameter, not an out-of-bounds index
            .AccessChain, .CopyObject => return if (inst.words.len > 3) a.pointerParamOf(params, inst.words[3], depth + 1) else null,
            .FunctionParameter => {
                for (params, 0..) |pid, pi| {
                    if (pid == ptr_id) return pi;
                }
                return null;
            },
            else => return null,
        }
    }

    /// Parse every function into blocks, call sites, stores and loops.
    fn parse(a: *UniformityAnalysis) !void {
        var funcs = std.ArrayListUnmanaged(UniFunc).empty;
        var label_maps = std.ArrayListUnmanaged(std.AutoHashMap(u32, usize)).empty;
        var loop_lists = std.ArrayListUnmanaged(std.ArrayListUnmanaged(UniLoop)).empty;
        const m = a.module;
        var i: usize = 0;
        while (i < m.instructions.len) : (i += 1) {
            if (m.instructions[i].op != .Function) continue;
            const func_id = if (m.instructions[i].words.len > 2) m.instructions[i].words[2] else 0;
            const my_index = funcs.items.len;
            var params = std.ArrayListUnmanaged(u32).empty;
            var blocks = std.ArrayListUnmanaged(UniBlock).empty;
            var terms = std.ArrayListUnmanaged(UniTerm).empty;
            var calls = std.ArrayListUnmanaged(UniCall).empty;
            var samples = std.ArrayListUnmanaged(UniSample).empty;
            var returns = std.ArrayListUnmanaged(UniReturn).empty;
            var derivs = std.ArrayListUnmanaged(UniSample).empty;
            var loops = std.ArrayListUnmanaged(UniLoop).empty;
            var cur_block: usize = 0;
            var j: usize = i + 1;
            while (j < m.instructions.len and m.instructions[j].op != .FunctionEnd) : (j += 1) {
                const inst = m.instructions[j];
                // Attribute every RESULT id in this function to it, so phi and
                // parameter classification can find the context. The id must
                // come from the same predicate the module parser used to build
                // id_defs: words[2] is a result only where the opcode HAS one
                // (for OpStore it is the stored value, for OpBranchConditional
                // the true label, for OpSelectionMerge the control-mask
                // LITERAL), and putting those in would attribute an unrelated
                // id to this function -- .Phi would then look up the wrong
                // block and call a uniform value non-uniform.
                if (common.resultIdFromOp(inst.op, inst.words)) |rid| {
                    if (inst.op != .Label) {
                        try a.owner_func.put(rid, my_index);
                        // #684: the store rule needs the load's block too.
                        // Same result-id predicate as owner_func, same guard.
                        try a.block_of.put(rid, cur_block);
                    }
                }
                switch (inst.op) {
                    .FunctionParameter => {
                        if (inst.words.len > 2) try params.append(a.arena, inst.words[2]);
                    },
                    .Label => {
                        if (inst.words.len > 1) {
                            try blocks.append(a.arena, .{ .label = inst.words[1], .term = .unreach, .succs = &.{} });
                            try terms.append(a.arena, .unreach);
                            cur_block = blocks.items.len - 1;
                        }
                    },
                    .Branch => {
                        if (inst.words.len > 1) terms.items[cur_block] = .{ .branch = inst.words[1] };
                    },
                    .BranchConditional => {
                        if (inst.words.len > 3) terms.items[cur_block] = .{ .cond = .{ .cond = inst.words[1], .t = inst.words[2], .f = inst.words[3] } };
                    },
                    .Switch => {
                        var targets = std.ArrayListUnmanaged(u32).empty;
                        if (inst.words.len > 2) {
                            try targets.append(a.arena, inst.words[2]); // default target
                            var wi: usize = 3;
                            while (wi + 1 < inst.words.len) : (wi += 2) {
                                try targets.append(a.arena, inst.words[wi + 1]);
                            }
                        }
                        terms.items[cur_block] = .{ .swit = .{ .sel = if (inst.words.len > 1) inst.words[1] else 0, .targets = targets.items } };
                    },
                    .Return => terms.items[cur_block] = .ret,
                    .ReturnValue => {
                        terms.items[cur_block] = .ret;
                        // #684: WHAT comes back and FROM WHERE (a return from
                        // a diverged arm is a non-uniform result for tint even
                        // when the value is uniform; words[1] is the value,
                        // OpReturnValue has no result id of its own).
                        if (inst.words.len > 1) try returns.append(a.arena, .{ .val = inst.words[1], .block = cur_block });
                    },
                    .Kill => terms.items[cur_block] = .kill,
                    .Unreachable => terms.items[cur_block] = .unreach,
                    .LoopMerge => {
                        // merge = words[1], continue = words[2]; the prelude
                        // and governing conditions are resolved after the
                        // whole function is parsed (targets are forward).
                        try loops.append(a.arena, .{
                            .header = cur_block,
                            .continue_block = null,
                            .prelude = &.{},
                            .governing = &.{},
                        });
                        try a.loop_merges.put(blocks.items[cur_block].label, .{
                            .merge = if (inst.words.len > 1) inst.words[1] else 0,
                            .cont = if (inst.words.len > 2) inst.words[2] else 0,
                        });
                    },
                    .FunctionCall => {
                        if (inst.words.len > 3) {
                            var args = std.ArrayListUnmanaged(u32).empty;
                            for (inst.words[4..]) |arg| try args.append(a.arena, arg);
                            try calls.append(a.arena, .{ .callee = inst.words[3], .block = cur_block, .args = args.items });
                            // Tie pointer arguments to the variables they
                            // alias so the callee's loads through them can be
                            // judged from the caller's stores. An argument
                            // that is neither a variable chain nor one of this
                            // function's own parameters makes the callee's
                            // parameter opaque (conservative non-uniform).
                            for (args.items, 0..) |arg, pos| {
                                if (a.pointerRoot(arg, 0)) |root| {
                                    try a.arg_vars.append(a.arena, .{ .callee = inst.words[3], .pos = pos, .root = root, .caller = my_index, .block = cur_block });
                                } else if (a.pointerParamOf(params.items, arg, 0)) |_| {
                                    const callee_idx = blk: {
                                        const fid = inst.words[3];
                                        for (funcs.items, 0..) |ff, ffi| {
                                            if (ff.id == fid) break :blk ffi;
                                        }
                                        break :blk null;
                                    };
                                    if (callee_idx) |ci| try a.opaque_params.put(packParamKey(ci, pos), {});
                                }
                            }
                        }
                    },
                    .Store => {
                        if (inst.words.len > 2) {
                            if (a.pointerRoot(inst.words[1], 0)) |root| {
                                try a.stores.append(a.arena, .{ .root = root, .val = inst.words[2], .func = my_index, .block = cur_block });
                            } else if (a.pointerParamOf(params.items, inst.words[1], 0)) |pi| {
                                try a.param_stores.append(a.arena, .{ .func = my_index, .param = pi, .val = inst.words[2], .block = cur_block });
                            }
                        }
                    },
                    .ImageSampleImplicitLod, .ImageSampleDrefImplicitLod, .ImageSampleProjImplicitLod, .ImageSampleProjDrefImplicitLod => {
                        if (inst.words.len > 2) {
                            try samples.append(a.arena, .{ .result = inst.words[2], .block = cur_block });
                        }
                    },
                    // #685: the derivative builtins are gated on uniform
                    // control flow by the same WGSL rule, and they have no
                    // lowered form, so a non-uniform one is REFUSED at
                    // emission rather than downgraded. Collected here so the
                    // fixpoint's flow verdict (including the interprocedural
                    // call-site rule) can mark them exactly as it marks
                    // samples. The list is every derivative opcode there is
                    // (spec 207-215: plain/Fine/Coarse dpdx, dpdy, fwidth;
                    // all named in spirv.Op, so no raw numeric gap applies).
                    .DPdx, .DPdy, .Fwidth, .DPdxFine, .DPdyFine, .FwidthFine, .DPdxCoarse, .DPdyCoarse, .FwidthCoarse => {
                        if (inst.words.len > 2) {
                            try derivs.append(a.arena, .{ .result = inst.words[2], .block = cur_block });
                        }
                    },
                    else => {
                        // OpTerminateInvocation is SPIR-V 1.6's OpKill: a
                        // DISCARD-LIKE block terminator. spirv.Op does not name
                        // it, so it cannot have a `.TerminateInvocation` arm and
                        // lands here; without this line the block would keep its
                        // `.unreach` default and `postdominates` would count it
                        // as an EXIT, which is the exact OPPOSITE of the
                        // deliberate OpKill rule documented there (a discard is a
                        // dead end, not a path that bypasses the merge). It gets
                        // the OpKill classification for the same reason: a
                        // terminated invocation contributes no path to a return.
                        // Nothing can observe this yet -- the WGSL emitter
                        // honest-errors on opcode 4416 ("unsupported op ... in
                        // main emit path"), so no module carrying one reaches
                        // emission -- but the classification is then already
                        // right the day the emitter grows a `discard;` arm.
                        if (isTerminateInvocation(inst.op)) terms.items[cur_block] = .kill;
                    },
                }
            }
            // resolve label ids -> block indices (targets may be defined later)
            var lmap = std.AutoHashMap(u32, usize).init(a.arena);
            for (blocks.items, 0..) |blk, bi| try lmap.put(blk.label, bi);
            var resolved = std.ArrayListUnmanaged(UniBlock).empty;
            for (blocks.items, 0..) |blk, bi| {
                const term = terms.items[bi];
                var succs = std.ArrayListUnmanaged(usize).empty;
                switch (term) {
                    .branch => |t| if (lmap.get(t)) |ti| try succs.append(a.arena, ti),
                    .cond => |c| {
                        if (lmap.get(c.t)) |ti| try succs.append(a.arena, ti);
                        if (lmap.get(c.f)) |ti| try succs.append(a.arena, ti);
                    },
                    .swit => |s| for (s.targets) |t| {
                        if (lmap.get(t)) |ti| try succs.append(a.arena, ti);
                    },
                    // terminators that leave the function: no successor block
                    .ret, .kill, .unreach => {},
                }
                try resolved.append(a.arena, .{ .label = blk.label, .term = term, .succs = succs.items });
            }
            // predecessor lists, once (the flow pass iterates them per block)
            {
                var preds = try a.arena.alloc(std.ArrayListUnmanaged(usize), resolved.items.len);
                for (preds) |*pl| pl.* = .empty;
                for (resolved.items, 0..) |blk, bi| {
                    for (blk.succs) |s| {
                        if (s < preds.len) try preds[s].append(a.arena, bi);
                    }
                }
                for (resolved.items, 0..) |*blk, bi| blk.preds = preds[bi].items;
            }
            // resolve each loop's prelude chain and governing conditions
            for (loops.items) |*lp| {
                var prelude = std.ArrayListUnmanaged(usize).empty;
                var governing = std.ArrayListUnmanaged(u32).empty;
                var cb: usize = lp.header;
                var guard: u32 = 0;
                while (guard < blocks.items.len + 1) : (guard += 1) {
                    try prelude.append(a.arena, cb);
                    switch (resolved.items[cb].term) {
                        .cond => |c| {
                            try governing.append(a.arena, c.cond);
                            break;
                        },
                        .swit => |s| {
                            try governing.append(a.arena, s.sel);
                            break;
                        },
                        .branch => |t| {
                            const nxt = lmap.get(t) orelse break;
                            if (nxt == cb) break; // degenerate self chain
                            cb = nxt;
                        },
                        // the header chain left the function before reaching any
                        // conditional: there is no trip-count condition to record
                        .ret, .kill, .unreach => break,
                    }
                }
                var continue_block: ?usize = null;
                if (a.loop_merges.getPtr(resolved.items[lp.header].label)) |lm| {
                    if (lmap.get(lm.cont)) |ci| {
                        continue_block = ci;
                        try prelude.append(a.arena, ci);
                        switch (resolved.items[ci].term) {
                            .cond => |c| try governing.append(a.arena, c.cond),
                            .swit => |s| try governing.append(a.arena, s.sel),
                            // an unconditional continue governs nothing
                            .branch, .ret, .kill, .unreach => {},
                        }
                    }
                }
                lp.continue_block = continue_block;
                lp.prelude = prelude.items;
                lp.governing = governing.items;
            }
            const param_uni = try a.arena.alloc(bool, params.items.len);
            @memset(param_uni, true);
            try funcs.append(a.arena, .{
                .id = func_id,
                .params = params.items,
                .blocks = resolved.items,
                .entry_block = 0,
                .calls = calls.items,
                .samples = samples.items,
                .returns = returns.items,
                .derivatives = derivs.items,
                .is_entry_point = func_id == a.module.entry_point_id,
                .entry_flow = true,
                .param_uniform = param_uni,
                .returns_uniform = true,
            });
            try label_maps.append(a.arena, lmap);
            try loop_lists.append(a.arena, loops);
            i = j;
        }
        a.funcs = funcs.items;
        a.label_to_block = label_maps.items;
        a.loops_of = loop_lists.items;
        const rows = try a.arena.alloc(?[]const []const bool, funcs.items.len);
        @memset(rows, null);
        a.reach_rows = rows;
        for (a.funcs, 0..) |*uf, fi| {
            try a.func_by_id.put(uf.id, fi);
            for (uf.params, 0..) |pid, pi| {
                try a.owner_func.put(pid, fi);
                try a.param_index.put(pid, pi);
            }
            for (a.loops_of[fi].items) |lp| {
                for (lp.prelude) |pb| try a.prelude_of.put(packFlowKey(fi, pb), @intCast(lp.header));
            }
        }
        // AFTER func_by_id exists: the cycle walk resolves callee ids.
        try a.computeRecursive();
    }

    /// Mark every function that can reach ITSELF through at least one call
    /// edge (self-recursion or a mutual cycle). Both #684 rules model ONE
    /// invocation of a function: a store reaches a load along a CFG path of
    /// the SAME invocation, and a return value is what ONE invocation returns.
    /// Recursion breaks both in the unsafe direction -- a store executed by an
    /// OUTER invocation can feed a load of an INNER one with no same-frame CFG
    /// path between them -- so functions on a cycle keep the pre-#684 rules.
    /// glslang cannot emit recursion (GLSL forbids it); this guard exists for
    /// hand-authored or external SPIR-V. O(F * (F + E)) on the call graph.
    fn computeRecursive(a: *UniformityAnalysis) !void {
        const rec = try a.arena.alloc(bool, a.funcs.len);
        @memset(rec, false);
        for (0..a.funcs.len) |fi| {
            a.visited.clearRetainingCapacity();
            a.dfs_stack.clearRetainingCapacity();
            for (a.funcs[fi].calls) |call| {
                if (a.func_by_id.get(call.callee)) |ci| try a.dfs_stack.append(a.arena, ci);
            }
            while (a.dfs_stack.items.len > 0) {
                const ci = a.dfs_stack.items[a.dfs_stack.items.len - 1];
                a.dfs_stack.items.len -= 1;
                if (ci == fi) {
                    rec[fi] = true;
                    break;
                }
                if (a.visited.contains(ci)) continue;
                try a.visited.put(ci, {});
                for (a.funcs[ci].calls) |call| {
                    if (a.func_by_id.get(call.callee)) |cj| try a.dfs_stack.append(a.arena, cj);
                }
            }
        }
        a.recursive_funcs = rec;
    }

    /// The transitive block-reachability rows of function `fi`, built on
    /// first use (most functions never need them: only a load of a
    /// Function/Output/Private-scope variable consults the store filter).
    /// Null only on allocation failure; callers treat that as "reachability
    /// unknown", i.e. every store counts (the conservative direction).
    fn reachRow(a: *UniformityAnalysis, fi: usize) ?[]const []const bool {
        if (fi >= a.funcs.len) return null;
        if (a.reach_rows[fi]) |rows| return rows;
        const uf = &a.funcs[fi];
        const rows = a.arena.alloc([]bool, uf.blocks.len) catch return null;
        for (rows) |*r| {
            const row = a.arena.alloc(bool, uf.blocks.len) catch return null;
            @memset(row, false);
            r.* = row;
        }
        for (0..uf.blocks.len) |from| {
            // a block trivially reaches itself: intra-block store/load order
            // is not modelled, so a store in the load's own block counts.
            rows[from][from] = true;
            a.visited.clearRetainingCapacity();
            a.dfs_stack.clearRetainingCapacity();
            a.visited.put(from, {}) catch return null;
            for (uf.blocks[from].succs) |s| a.dfs_stack.append(a.arena, s) catch return null;
            while (a.dfs_stack.items.len > 0) {
                const bi = a.dfs_stack.items[a.dfs_stack.items.len - 1];
                a.dfs_stack.items.len -= 1;
                if (a.visited.contains(bi)) continue;
                a.visited.put(bi, {}) catch return null;
                rows[from][bi] = true;
                for (uf.blocks[bi].succs) |s| a.dfs_stack.append(a.arena, s) catch return null;
            }
        }
        a.reach_rows[fi] = rows;
        return rows;
    }

    /// Can block `from` reach block `to` in function `fi`'s successor graph?
    /// Answers TRUE whenever the answer is unavailable (no such function,
    /// allocation failure, out-of-range block): this is a MAY-WRITE filter
    /// for the store rule, so "cannot prove irrelevance" must mean "counts",
    /// never the other way.
    fn blockReaches(a: *UniformityAnalysis, fi: usize, from: usize, to: usize) bool {
        const rows = a.reachRow(fi) orelse return true;
        if (from >= rows.len or to >= rows.len) return true;
        return rows[from][to];
    }

    /// Does block `target` postdominate block `from`: does every path from
    /// `from` to a function exit pass through `target`? Computed as a DFS
    /// from `from` that AVOIDS `target`; if it still reaches an exit block
    /// (OpReturn/OpReturnValue/OpUnreachable) then a path bypasses `target`.
    /// OpKill is deliberately NOT an exit (probe p20: a discard does not
    /// poison the following flow, so kill paths are dead ends, not exits).
    ///
    /// An allocation failure in the DFS scratch answers `false` (no
    /// postdominance) rather than propagating: the caller chain is all `bool`.
    /// That is the CONSERVATIVE direction -- it can only cost extra
    /// downgrades, never an implicit sample tint would reject -- but it does
    /// mean a shader compiled under memory pressure can pick a different mip
    /// than the same shader compiled normally.
    fn postdominates(a: *UniformityAnalysis, fi: usize, from: usize, target: usize) bool {
        const uf = &a.funcs[fi];
        a.visited.clearRetainingCapacity();
        a.dfs_stack.clearRetainingCapacity();
        for (uf.blocks[from].succs) |s| a.dfs_stack.append(a.arena, s) catch return false;
        while (a.dfs_stack.items.len > 0) {
            const bi = a.dfs_stack.items[a.dfs_stack.items.len - 1];
            a.dfs_stack.items.len -= 1;
            if (bi == target) continue;
            if (a.visited.contains(bi)) continue;
            a.visited.put(bi, {}) catch return false;
            switch (uf.blocks[bi].term) {
                .ret, .unreach => return false, // an exit path avoids `target`
                // .kill is deliberately NOT an exit (see the doc comment); the
                // rest have successors the DFS keeps walking.
                .branch, .cond, .swit, .kill => {},
            }
            for (uf.blocks[bi].succs) |s| a.dfs_stack.append(a.arena, s) catch return false;
        }
        return true;
    }

    /// The loop whose prelude contains `bi`, or null.
    fn preludeLoop(a: *UniformityAnalysis, fi: usize, bi: usize) ?*UniLoop {
        const header = a.prelude_of.get(packFlowKey(fi, bi)) orelse return null;
        for (a.loops_of[fi].items) |*lp| {
            if (lp.header == header) return lp;
        }
        return null;
    }

    /// The flow a block contributes when reconvergence at its target makes
    /// the branch's divergence irrelevant: the loop's ENTRY flow for prelude
    /// blocks, the block's own flow elsewhere.
    fn regionEntry(a: *UniformityAnalysis, fi: usize, bi: usize, depth: u32) bool {
        if (depth > max_flow_depth) return false;
        if (a.preludeLoop(fi, bi)) |lp| return a.loopEntryFlow(fi, lp.header, depth + 1);
        return a.funcs[fi].blocks[bi].flow;
    }

    /// A loop header's entry flow: the OR of its non-back-edge incoming
    /// contributions (the back edge arrives per-iteration and is judged by
    /// the governing condition instead).
    fn loopEntryFlow(a: *UniformityAnalysis, fi: usize, header: usize, depth: u32) bool {
        if (depth > max_flow_depth) return false;
        const uf = &a.funcs[fi];
        var f = if (header == uf.entry_block) uf.entry_flow else false;
        for (uf.blocks[header].preds) |pi| {
            if (pi >= uf.blocks.len) continue;
            // skip the loop's own back edge (from the continue block)
            if (a.preludeLoop(fi, header)) |lp| {
                if (lp.continue_block == pi) continue;
            }
            if (a.edgeContribution(fi, pi, header, depth + 1)) f = true;
        }
        return f;
    }

    /// Is the edge from block `pi` into block `ti` a uniform edge?
    ///   OpBranch: uniform iff the source block's flow is uniform.
    ///   Conditional/switch on a UNIFORM value: same as OpBranch.
    ///   Conditional/switch on a NON-uniform value: uniform iff `ti`
    ///   postdominates `pi` (every invocation reconverges there), and then
    ///   the flow that survives is the REGION ENTRY flow (probe p10).
    fn edgeContribution(a: *UniformityAnalysis, fi: usize, pi: usize, ti: usize, depth: u32) bool {
        if (depth > max_flow_depth) return false;
        const uf = &a.funcs[fi];
        switch (uf.blocks[pi].term) {
            .branch => return uf.blocks[pi].flow,
            .cond => |c| {
                if (a.values.contains(c.cond)) return uf.blocks[pi].flow;
                return a.postdominates(fi, pi, ti) and a.regionEntry(fi, pi, depth + 1);
            },
            .swit => |s| {
                if (a.values.contains(s.sel)) return uf.blocks[pi].flow;
                return a.postdominates(fi, pi, ti) and a.regionEntry(fi, pi, depth + 1);
            },
            // a block that leaves the function has no edge into `ti` at all;
            // reaching here means the pred list disagrees with the terminator
            // (truncated/malformed input), so contribute nothing.
            .ret, .kill, .unreach => return false,
        }
    }

    /// Recompute the flow of every block of function `fi` from the current
    /// value state and entry flow; returns true when ANY block's flow changed.
    /// The outer fixpoint reads that as "not stable yet", which is sound
    /// because flow is monotone here: `entry_flow` and the value set only ever
    /// move DOWN, so a block's flow only ever moves true -> false and "any
    /// change" and "moved true -> false" are the same predicate.
    /// Flow is an OR over incoming contributions: a block is uniform when some
    /// incoming edge delivers the full invocation set (either directly, or by
    /// reconverging every path that diverged).
    fn recomputeFlow(a: *UniformityAnalysis, fi: usize) bool {
        const uf = &a.funcs[fi];
        if (uf.blocks.len == 0) return false;
        var changed = true;
        var any_changed = false;
        while (changed) {
            changed = false;
            for (uf.blocks, 0..) |*b, bi| {
                var f = if (bi == uf.entry_block) uf.entry_flow else false;
                for (b.preds) |pi| {
                    if (pi >= uf.blocks.len) continue;
                    if (a.edgeContribution(fi, pi, bi, 0)) f = true;
                }
                // Prelude blocks (loop header chain + continue block) execute
                // once PER ITERATION: their flow is the loop entry flow gated
                // by the uniformity of the trip-count conditions.
                if (a.preludeLoop(fi, bi)) |lp| {
                    var g = a.loopEntryFlow(fi, lp.header, 0);
                    for (lp.governing) |cond| {
                        if (!a.values.contains(cond)) g = false;
                    }
                    // A loop with no conditional at all (pure `while (true)`
                    // with breaks) has a condition-dependent trip count that
                    // cannot be proven uniform: stay conservative.
                    if (lp.governing.len == 0) g = false;
                    f = g;
                }
                if (f != b.flow) {
                    b.flow = f;
                    changed = true;
                    any_changed = true;
                }
            }
        }
        return any_changed;
    }

    /// Pure value-propagating ops: a result is uniform when every id operand
    /// is uniform. Deliberately EXCLUDES loads, samples, derivatives, calls
    /// and anything memory- or side-effect-ful (never uniform here).
    fn isPureValueOp(op: spirv.Op) bool {
        return switch (op) {
            .SNegate, .FNegate, .Not => true,
            .IAdd, .FAdd, .ISub, .FSub, .IMul, .FMul => true,
            .UDiv, .SDiv, .FDiv, .UMod, .SMod, .SRem, .FMod, .FRem => true,
            .VectorTimesScalar, .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix, .OuterProduct, .Transpose, .Dot => true,
            .LogicalEqual, .LogicalNotEqual, .LogicalOr, .LogicalAnd, .LogicalNot => true,
            .IEqual, .INotEqual, .UGreaterThan, .SGreaterThan, .UGreaterThanEqual, .SGreaterThanEqual, .ULessThan, .SLessThan, .ULessThanEqual, .SLessThanEqual => true,
            .FOrdEqual, .FUnordEqual, .FOrdNotEqual, .FUnordNotEqual, .FOrdLessThan, .FUnordLessThan, .FOrdGreaterThan, .FUnordGreaterThan, .FOrdLessThanEqual, .FUnordLessThanEqual, .FOrdGreaterThanEqual, .FUnordGreaterThanEqual => true,
            .ShiftRightLogical, .ShiftRightArithmetic, .ShiftLeftLogical, .BitwiseOr, .BitwiseXor, .BitwiseAnd => true,
            .BitReverse, .BitCount, .BitFieldInsert, .BitFieldSExtract, .BitFieldUExtract => true,
            .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU, .UConvert, .SConvert, .FConvert, .QuantizeToF16, .Bitcast => true,
            .IsNan, .IsInf, .All, .Any => true,
            .CompositeConstruct, .CopyObject => true,
            .Select => true,
            else => false,
        };
    }

    /// For a phi incoming from block `pb`: was the BRANCH that left `pb`
    /// uniform? A value arriving via a diverged edge is a non-uniform
    /// SELECTION even when every incoming value is a uniform constant
    /// (probe p17).
    fn phiEdgeUniform(a: *UniformityAnalysis, fi: usize, pb: usize) bool {
        const uf = &a.funcs[fi];
        switch (uf.blocks[pb].term) {
            .cond => |c| return a.values.contains(c.cond),
            .swit => |s| return a.values.contains(s.sel),
            // an unconditional branch selects nothing, so the edge is uniform
            .branch, .ret, .kill, .unreach => return true,
        }
    }

    /// Is `root` a FUNCTION-scope variable? The #684 reachability filter is
    /// only sound for those: a Function-scope variable's contents live and
    /// die with ONE invocation, so a store cannot feed a load no CFG path
    /// leads to. A module-scope Private or Output variable PERSISTS across
    /// sequential invocations of the same function, so a store made by an
    /// earlier call can feed a load of a later one from an unreachable block
    /// (the #684 review repro), and tint poisons such reads from a
    /// non-uniform store anywhere in the module. Anything that is not a
    /// Function-scope variable (or whose definition cannot be read) keeps the
    /// flow-insensitive rule: every store counts.
    fn rootScopeIsFunction(a: *UniformityAnalysis, root: u32) bool {
        const rdef = common.getDef(a.module, root) orelse return false;
        if (rdef.words.len <= 3) return false;
        const sc: spirv.StorageClass = @enumFromInt(rdef.words[3]);
        return sc == .Function;
    }

    /// Every store into `root` that can REACH the load at `loc` (direct, and
    /// through any pointer parameter a callee received for it) wrote a uniform
    /// value from uniform flow. glslang lowers assigned locals AND helper
    /// parameters to variables, so this store rule is how uniform values
    /// actually travel (probe p24 vs p17).
    ///
    /// #684 made the rule FLOW-SENSITIVE for stores in the SAME function as
    /// the load: a store whose block cannot reach the load's block on any CFG
    /// path can never write the value the load reads, so reusing a scratch
    /// local for a later value must not poison the earlier loads. The filter
    /// argues about ONE invocation, so it is disabled for functions on a
    /// call-graph cycle, for stores made in a DIFFERENT function (cross-
    /// invocation reachability is not modelled), and for roots that are not
    /// Function-scope (see rootScopeIsFunction: module-scope Private/Output
    /// storage persists across calls of the same function, which is the same
    /// hole cross-function stores already cover).
    fn varStoresUniform(a: *UniformityAnalysis, root: u32, loc: ?UniLoc) bool {
        // The verdict is an AND, so the first failing store settles it: return
        // instead of carrying an `ok = false` through the rest of the (flat,
        // whole-module) store list.
        const l = loc orelse UniLoc{ .func = std.math.maxInt(usize), .block = 0 };
        const use_reach = l.func < a.funcs.len and !a.recursive_funcs[l.func] and a.rootScopeIsFunction(root);
        for (a.stores.items) |st| {
            if (st.root != root) continue;
            if (use_reach and st.func == l.func and !a.blockReaches(l.func, st.block, l.block)) continue;
            if (!a.values.contains(st.val)) return false;
            if (st.func >= a.funcs.len) continue;
            if (st.block >= a.funcs[st.func].blocks.len) continue;
            if (!a.funcs[st.func].blocks[st.block].flow) return false;
        }
        // stores a callee makes through the pointer it was handed for `root`:
        // only call sites that can feed the load matter (the callee's store
        // executes iff the call does, and it feeds the load iff control can
        // still reach the load after the call returns)
        for (a.arg_vars.items) |av| {
            if (av.root != root) continue;
            if (use_reach and av.caller == l.func and !a.blockReaches(l.func, av.block, l.block)) continue;
            const ci = a.func_by_id.get(av.callee) orelse return false;
            if (!a.paramStoresUniform(ci, av.pos)) return false;
        }
        return true;
    }

    /// Every store through parameter `pi` of function `fi` wrote a uniform
    /// value from uniform flow (and the parameter never aliases something
    /// unresolvable).
    fn paramStoresUniform(a: *UniformityAnalysis, fi: usize, pi: usize) bool {
        if (a.opaque_params.contains(packParamKey(fi, pi))) return false;
        for (a.param_stores.items) |st| {
            if (st.func != fi or st.param != pi) continue;
            if (!a.values.contains(st.val)) return false;
            if (st.func >= a.funcs.len) continue;
            if (st.block >= a.funcs[fi].blocks.len) continue;
            if (!a.funcs[fi].blocks[st.block].flow) return false;
        }
        return true;
    }

    /// A load through pointer parameter `pi` of function `fi` is a uniform
    /// value iff every caller handed it a variable that only ever holds
    /// uniform values (probe p23a/p23b: tint tracks the argument). `loc` is
    /// where the load sits; it only sharpens the store filter for stores into
    /// the variable made in this same function (`fi`), since the caller's
    /// stores are cross-function and count unconditionally.
    fn loadThroughParamUniform(a: *UniformityAnalysis, fi: usize, pi: usize, loc: ?UniLoc) bool {
        var seen = false;
        const fid = a.funcs[fi].id;
        for (a.arg_vars.items) |av| {
            if (av.callee != fid or av.pos != pi) continue;
            seen = true;
            if (!a.varStoresUniform(av.root, loc)) return false;
        }
        // no call site handed this parameter a variable: nothing to judge from
        return seen;
    }

    /// Classify whether `id` holds a uniform value under the CURRENT state.
    fn valueIsUniform(a: *UniformityAnalysis, id: u32) bool {
        const inst = common.getDef(a.module, id) orelse return false;
        switch (inst.op) {
            .ConstantTrue, .ConstantFalse, .Constant, .ConstantNull, .SpecConstant, .SpecConstantTrue, .SpecConstantFalse => return true,
            .ConstantComposite, .SpecConstantComposite => {
                for (inst.words[3..]) |c| {
                    if (!a.values.contains(c)) return false;
                }
                return true;
            },
            .Load => {
                // getDef only guarantees words.len >= 3; OpLoad's pointer
                // operand is words[3], so a truncated load would index past the
                // end. Conservative answer: not a uniform value.
                if (inst.words.len <= 3) return false;
                const ptr = inst.words[3];
                // #684: WHERE this load sits, for the flow-sensitive store
                // rule. An unknown function or block disables the filter
                // (every store counts), which is the conservative direction.
                const owner = a.owner_func.get(id);
                const loc: ?UniLoc = if (owner) |fi| blk: {
                    const bi = a.block_of.get(id) orelse break :blk null;
                    if (bi >= a.funcs[fi].blocks.len) break :blk null;
                    break :blk UniLoc{ .func = fi, .block = bi };
                } else null;
                // A load through a pointer parameter of the owning function
                // (glslang's parameter ABI) is judged from the arguments.
                if (owner) |fi| {
                    if (a.pointerParamOf(a.funcs[fi].params, ptr, 0)) |pi| {
                        return a.loadThroughParamUniform(fi, pi, loc);
                    }
                }
                const root = a.pointerRoot(ptr, 0) orelse return false;
                const rdef = common.getDef(a.module, root) orelse return false;
                if (rdef.words.len <= 3) return false;
                const sc: spirv.StorageClass = @enumFromInt(rdef.words[3]);
                if (a.readIsUniformStorage(root, sc)) {
                    // probe p22: every dynamic index in the chain must itself
                    // be a uniform value, or the loaded element varies.
                    return a.chainIndicesUniform(ptr, 0);
                }
                if (sc == .Function or sc == .Output or sc == .Private) {
                    return a.varStoresUniform(root, loc);
                }
                return false;
            },
            .FunctionParameter => {
                const fi = a.owner_func.get(id) orelse return false;
                const pi = a.param_index.get(id) orelse return false;
                return a.funcs[fi].param_uniform[pi];
            },
            .Phi => {
                const fi = a.owner_func.get(id) orelse return false;
                const uf = &a.funcs[fi];
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const in_val = inst.words[wi];
                    const in_parent = inst.words[wi + 1];
                    if (!a.values.contains(in_val)) return false;
                    const pb = a.label_to_block[fi].get(in_parent) orelse return false;
                    if (!uf.blocks[pb].flow) return false;
                    if (!a.phiEdgeUniform(fi, pb)) return false;
                }
                return true;
            },
            .CompositeExtract => return inst.words.len > 3 and a.values.contains(inst.words[3]),
            .VectorShuffle => {
                return inst.words.len > 4 and a.values.contains(inst.words[3]) and a.values.contains(inst.words[4]);
            },
            .CompositeInsert => {
                return inst.words.len > 4 and a.values.contains(inst.words[3]) and a.values.contains(inst.words[4]);
            },
            .ExtInst => {
                // GLSL.std.450 pure math; id operands start at words[5]. Any
                // pointer operand (Modf/Frexp) is never a uniform value, so
                // those forms refuse themselves.
                // A well-formed OpExtInst is at least 5 words (result type,
                // result id, set id, instruction literal); getDef only
                // guarantees 3, so a truncated one must answer non-uniform
                // rather than slice past the end.
                if (inst.words.len < 5) return false;
                for (inst.words[5..]) |op_id| {
                    if (!a.values.contains(op_id)) return false;
                }
                return true;
            },
            // #684: tint tracks return-value uniformity, so a call whose
            // callee only returns uniform values from uniform flow IS a
            // uniform value (probed on tint: accepted). The old blanket
            // "never uniform" silently downgraded samples gated by such
            // helpers, changing mip selection with no diagnostic. Note the
            // call SITE's flow deliberately plays no part: a uniform value
            // stays a uniform value wherever it is computed; where it is
            // STORED is already judged by the store rule.
            .FunctionCall => {
                // words[3] is the callee; getDef only guarantees 3 words, and
                // a call to a function this prepass never saw has no verdict
                // to consult: both answer non-uniform.
                if (inst.words.len <= 3) return false;
                const ci = a.func_by_id.get(inst.words[3]) orelse return false;
                return a.funcs[ci].returns_uniform;
            },
            else => {
                if (!isPureValueOp(inst.op)) return false;
                for (inst.words[3..]) |op_id| {
                    if (!a.values.contains(op_id)) return false;
                }
                return true;
            },
        }
    }

    /// Is a read through the variable `root` (storage class `sc`) a UNIFORM
    /// value for WGSL's own uniformity analysis?
    ///
    /// The answer must be decided by the ADDRESS SPACE THIS BACKEND EMITS, not
    /// by the SPIR-V storage class, because the two are not in bijection:
    ///   * StorageClass Uniform is a real UBO (`var<uniform>`, uniform read)
    ///     UNLESS the block struct carries BufferBlock, which is how glslang
    ///     targeting Vulkan 1.0 spells an SSBO -- that emits `var<storage, ...>`.
    ///   * StorageClass StorageBuffer (glslang from Vulkan 1.1 on, and tint)
    ///     is always an SSBO.
    /// A storage buffer is then a uniform read only when it is READ-ONLY:
    /// WGSL's uniformity analysis treats a `var<storage>` read as uniform and a
    /// `var<storage, read_write>` read as non-uniform (the same rule the
    /// .StorageBuffer emission arm documents). PushConstant has no WGSL address
    /// space and is emitted as a plain uniform buffer, so it is a uniform read.
    ///
    /// Deciding this from the storage class alone was wrong in BOTH directions:
    /// a Vulkan-1.0 SSBO was called uniform (the implicit sample was kept and
    /// tint rejected the module -- the very black-shader failure this prepass
    /// exists to prevent), while the SAME GLSL built for Vulkan 1.1 with
    /// `readonly` was called non-uniform and needlessly downgraded.
    fn readIsUniformStorage(a: *UniformityAnalysis, root: u32, sc: spirv.StorageClass) bool {
        switch (sc) {
            .PushConstant => return true,
            .Uniform, .StorageBuffer => {},
            else => return false,
        }
        const is_ssbo = if (sc == .StorageBuffer) true else blk: {
            const vdef = common.getDef(a.module, root) orelse break :blk false;
            if (vdef.words.len <= 1) break :blk false;
            const ptr_inst = common.getDef(a.module, vdef.words[1]) orelse break :blk false;
            if (ptr_inst.op != .TypePointer or ptr_inst.words.len <= 3) break :blk false;
            break :blk hasDec(a.decorations, arrayElementType(a.module, ptr_inst.words[3]), .buffer_block);
        };
        if (!is_ssbo) return true; // a real UBO
        return hasDec(a.decorations, root, .non_writable);
    }

    /// Every dynamic index of an access chain rooted at `ptr_id` is a
    /// uniform value (probe p22).
    fn chainIndicesUniform(a: *UniformityAnalysis, ptr_id: u32, depth: u32) bool {
        if (depth > max_flow_depth) return false;
        const inst = common.getDef(a.module, ptr_id) orelse return false;
        switch (inst.op) {
            .Variable => return true,
            .AccessChain => {
                // base operand at words[3], indices from words[4]; getDef only
                // guarantees 3 words, so a truncated chain answers non-uniform
                // rather than indexing past the end.
                if (inst.words.len <= 3) return false;
                for (inst.words[4..]) |idx| {
                    if (!a.values.contains(idx)) return false;
                }
                return a.chainIndicesUniform(inst.words[3], depth + 1);
            },
            .CopyObject => return if (inst.words.len > 3) a.chainIndicesUniform(inst.words[3], depth + 1) else false,
            else => return false,
        }
    }
};

/// pack a (function, block) pair into one key for the prelude map
fn packFlowKey(fi: usize, bi: usize) u64 {
    return (@as(u64, @intCast(fi)) << 32) | @as(u64, @intCast(bi));
}

/// pack a (function, parameter index) pair into one key
fn packParamKey(fi: usize, pi: usize) u64 {
    return (@as(u64, @intCast(fi)) << 32) | @as(u64, @intCast(pi));
}

/// Raw OpLoopMerge data recorded during parse, resolved once the function's
/// blocks all exist.
const UniLoopMerge = struct { merge: u32, cont: u32 };

/// Compute the set of RESULT ids of the UNIFORMITY-GATED builtins (the
/// implicit-Lod samples AND, since #685, the nine derivative opcodes) that sit
/// in non-uniform control flow in the generated WGSL. The emitter consults the
/// map at each gated builtin: a marked sample is LOWERED to the uniformity-safe
/// explicit-Level form, a marked derivative is REFUSED (there is no lowered
/// form for one; see recordUnsupportedNonuniformDerivative in
/// spirv_to_wgsl.zig). Empty (not an error) for the common module with neither.
///
/// The error set is written out rather than inferred (see `Error`). Spelling
/// it is what makes adding another failure a visible, reviewable change, and
/// what pins `UniformityAnalysisDidNotConverge` as the ONLY non-OOM failure
/// this prepass can produce, which is what the cli.zig detail gate relies on.
/// The human-readable detail for that error is recorded by the CALLER: this
/// module has no error-detail channel of its own.
///
/// LIFETIME: the returned map (and only it) is allocated from `result_arena`
/// and lives as long as the caller's arena does; every per-function block and
/// predecessor array, label map, reachability row and DFS stack the analysis
/// builds lives in an arena this function owns and is FREED when it returns
/// (before this owned its scratch, all of it came from the compile-wide arena
/// and stayed resident through the whole emission phase although only the
/// returned map is read afterwards).
pub fn computeNonuniformGatedBuiltinIds(
    result_arena: std.mem.Allocator,
    module: *const ParsedModule,
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
) Error!std.AutoHashMap(u32, void) {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var out = std.AutoHashMap(u32, void).init(result_arena);
    var a = UniformityAnalysis{
        .module = module,
        .decorations = decorations,
        .arena = arena,
        .funcs = &.{},
        .func_by_id = std.AutoHashMap(u32, usize).init(arena),
        .label_to_block = &.{},
        .loops_of = &.{},
        .owner_func = std.AutoHashMap(u32, usize).init(arena),
        .block_of = std.AutoHashMap(u32, usize).init(arena),
        .param_index = std.AutoHashMap(u32, usize).init(arena),
        .values = std.AutoHashMap(u32, void).init(arena),
        .opaque_params = std.AutoHashMap(u64, void).init(arena),
        .prelude_of = std.AutoHashMap(u64, u64).init(arena),
        .loop_merges = std.AutoHashMap(u32, UniLoopMerge).init(arena),
        .visited = std.AutoHashMap(usize, void).init(arena),
    };
    try a.parse();
    if (a.funcs.len == 0) return out;

    // Optimistic init: every id is a uniform value until proven otherwise.
    // Every component of the fixpoint below only ever moves DOWN, so it
    // terminates; the round cap is paranoia against hostile input.
    for (module.id_defs, 0..) |def, id| {
        if (def != null) try a.values.put(@intCast(id), {});
    }

    // Round cap: paranoia against hostile input, NOT an expected exit. Every
    // fixpoint component only moves DOWN, so convergence is bounded by the id
    // count; a module that still has not settled after 1000 rounds means an
    // invariant broke. Exiting quietly there would ship the LAST round's
    // half-settled answer, which is OPTIMISTIC (values still marked uniform
    // that another round would have cleared) and so can keep an implicit
    // sample tint rejects: the exact silent-wrong this prepass exists to
    // prevent. Fail loud instead.
    //
    // Why fail loud and not fail SAFE (mark every implicit sample non-uniform
    // and carry on)? Fail-safe would compile, but it would silently change mip
    // selection for every sample in the module -- a visibly different image
    // from a bug nobody was told about, which is the failure mode this whole
    // prepass exists to remove. A refusal is loud, actionable and rare (no
    // input has ever reached it), so it is the honest trade here.
    // (`max_rounds` is the pub const above so the backend's detail message
    // cites the same number.)
    // Per-round scratch, hoisted OUT of the loop: `arena` never frees, so
    // allocating these inside it burned one fresh allocation per round each,
    // up to 1000 of them on a module that runs the cap out. Both are fully
    // reset at the top of the step that uses them, so hoisting is behaviour
    // preserving.
    var to_remove = std.ArrayListUnmanaged(u32).empty;
    const new_flow = try arena.alloc(bool, a.funcs.len);
    var rounds: u32 = 0;
    var stable = false;
    while (!stable and rounds < max_rounds) : (rounds += 1) {
        stable = true;
        // 1. block flows from the current values and entry flows
        for (0..a.funcs.len) |fi| {
            if (a.recomputeFlow(fi)) stable = false;
        }
        // 2. value uniformity from the current values and flows
        {
            to_remove.clearRetainingCapacity();
            var vit = a.values.iterator();
            while (vit.next()) |entry| {
                if (!a.valueIsUniform(entry.key_ptr.*)) try to_remove.append(arena, entry.key_ptr.*);
            }
            if (to_remove.items.len > 0) {
                stable = false;
                for (to_remove.items) |id| _ = a.values.remove(id);
            }
        }
        // 3. a callee's ENTRY flow is the AND of its call sites' block flows
        //    (probe p11/p12). The entry point starts uniform and stays so.
        {
            @memset(new_flow, true);
            for (a.funcs, 0..) |caller, fi| {
                for (caller.calls) |call| {
                    const ci = a.func_by_id.get(call.callee) orelse continue;
                    if (ci == fi) continue; // self-recursion adds no information
                    if (!caller.blocks[call.block].flow) new_flow[ci] = false;
                }
            }
            for (a.funcs, 0..) |uf, fi| {
                if (uf.is_entry_point) continue;
                if (new_flow[fi] != uf.entry_flow) {
                    a.funcs[fi].entry_flow = new_flow[fi];
                    stable = false;
                }
            }
        }
        // 4. a PARAMETER is a uniform value iff every call site passes a
        //    uniform argument (probe p23a/p23b)
        for (a.funcs, 0..) |caller, fi| {
            for (caller.calls) |call| {
                const ci = a.func_by_id.get(call.callee) orelse continue;
                if (ci == fi) continue;
                const callee = &a.funcs[ci];
                for (call.args, 0..) |arg, ai| {
                    if (ai >= callee.params.len) break;
                    if (!a.values.contains(arg) and callee.param_uniform[ai]) {
                        callee.param_uniform[ai] = false;
                        stable = false;
                    }
                }
            }
        }
        // 5. (#684) a function's RESULT is a uniform value iff every
        //    OpReturnValue returns a uniform value FROM A BLOCK WITH UNIFORM
        //    FLOW. The block half is load-bearing, probed on tint: a uniform
        //    value returned from a DIVERGED arm is a non-uniform result (which
        //    return fired was selected by diverged flow, the same selection
        //    rule as a phi edge, probe p17), while a return after a
        //    reconverged if, or selected by a uniform condition, stays
        //    uniform. Value-only would be unsound here. The flow consulted is
        //    the callee's own, whose entry is the AND of its call sites, so a
        //    helper with one non-uniform call site has its result called
        //    non-uniform everywhere (tint would keep it at the uniform sites);
        //    that costs keeps, never correctness. Functions on a call-graph
        //    cycle keep the pre-#684 verdict: never a uniform result.
        for (a.funcs, 0..) |*uf, fi| {
            if (a.recursive_funcs[fi]) {
                if (uf.returns_uniform) {
                    uf.returns_uniform = false;
                    stable = false;
                }
                continue;
            }
            var ru = true;
            for (uf.returns) |r| {
                if (!a.values.contains(r.val)) {
                    ru = false;
                    break;
                }
                if (r.block >= uf.blocks.len or !uf.blocks[r.block].flow) {
                    ru = false;
                    break;
                }
            }
            if (ru != uf.returns_uniform) {
                uf.returns_uniform = ru;
                stable = false;
            }
        }
    }

    if (!stable) {
        // The detail message is recorded by the caller (spirvToWGSL), which
        // owns the backend's error-detail channel; see the entry-point doc.
        return error.UniformityAnalysisDidNotConverge;
    }

    for (a.funcs) |uf| {
        for (uf.samples) |s| {
            if (!uf.blocks[s.block].flow) try out.put(s.result, {});
        }
        // #685: same verdict, different consumer decision. A derivative in
        // non-uniform flow has no lowered form (WGSL offers no
        // explicit-derivative spelling to pin anything to), so its result id
        // goes into the SAME map and the derivative arms of the emitter
        // refuse on it rather than downgrade.
        for (uf.derivatives) |d| {
            if (!uf.blocks[d.block].flow) try out.put(d.result, {});
        }
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
// In-file unit tests. Possible only since the #691 extraction: before it this
// machinery lived inside spirv_to_wgsl.zig, where a rule change was observable
// only through the whole 14k-line emitter (tests/wgsl_tests.zig still carries
// those end-to-end tests; these pin the pieces they could never isolate).

/// A UniformityAnalysis hand-built around one function's block graph, for the
/// tests that exercise a single query in isolation (reachability, postdominance).
/// Everything the queried helper does not touch is left undefined; the fields
/// it does touch (funcs, reach_rows, the DFS scratch) are set up for real.
fn analysisForBlocks(arena: std.mem.Allocator, blocks: []UniBlock) !UniformityAnalysis {
    const rows = try arena.alloc(?[]const []const bool, 1);
    rows[0] = null;
    const funcs = try arena.alloc(UniFunc, 1);
    funcs[0] = .{
        .id = 1,
        .params = &.{},
        .blocks = blocks,
        .entry_block = 0,
        .calls = &.{},
        .samples = &.{},
        .returns = &.{},
        .derivatives = &.{},
        .is_entry_point = true,
        .param_uniform = &.{},
    };
    return .{
        .module = undefined,
        .decorations = undefined,
        .arena = arena,
        .funcs = funcs,
        .func_by_id = std.AutoHashMap(u32, usize).init(arena),
        .label_to_block = &.{},
        .owner_func = std.AutoHashMap(u32, usize).init(arena),
        .block_of = std.AutoHashMap(u32, usize).init(arena),
        .param_index = std.AutoHashMap(u32, usize).init(arena),
        .values = std.AutoHashMap(u32, void).init(arena),
        .opaque_params = std.AutoHashMap(u64, void).init(arena),
        .prelude_of = std.AutoHashMap(u64, u64).init(arena),
        .loops_of = &.{},
        .loop_merges = std.AutoHashMap(u32, UniLoopMerge).init(arena),
        .visited = std.AutoHashMap(usize, void).init(arena),
        .reach_rows = rows,
    };
}

test "packFlowKey/packParamKey disambiguate every in-domain pair" {
    // Both packers fold two usize indices into one u64 key, so the property
    // the prelude/param maps rely on is injectivity: two different (fi, bi)
    // pairs must never share a flow key, and two different (fi, pi) pairs
    // must never share a param key. The halves are valid while both indices
    // stay below 2^32 (a function index and a block/param index are bounded
    // by the module's instruction count, which cannot approach that).
    const flow_keys = [_][2]usize{
        .{ 0, 0 },         .{ 0, 1 },         .{ 1, 0 },         .{ 1, 1 },
        .{ 7, 3 },         .{ 3, 7 },         .{ 42, 1 << 20 },  .{ 1 << 20, 42 },
        .{ 65535, 65535 }, .{ 65536, 65535 }, .{ 65535, 65536 },
    };
    for (flow_keys, 0..) |a, i| {
        const ka = packFlowKey(a[0], a[1]);
        // halves round-trip (the packing is a plain shift-or)
        try std.testing.expectEqual(@as(u64, a[0]), ka >> 32);
        try std.testing.expectEqual(@as(u64, a[1]), ka & 0xffffffff);
        for (flow_keys[i + 1 ..]) |b| {
            const kb = packFlowKey(b[0], b[1]);
            if (a[0] != b[0] or a[1] != b[1]) {
                try std.testing.expect(ka != kb);
            }
        }
    }
    // packParamKey carries the same property for the param space; it keys a
    // SEPARATE map (opaque_params), so a flow key and a param key can never
    // collide with each other even though the encodings are identical.
    try std.testing.expectEqual(packFlowKey(3, 4), packParamKey(3, 4));
    try std.testing.expect(packFlowKey(1, 2) != packFlowKey(2, 1));
    try std.testing.expect(packParamKey(1, 2) != packParamKey(2, 1));
}

test "reachRow closure includes back edges and the diagonal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // b0 -> b1 -> b2 -> {b0, b3}; b3 is the ret exit. A loop with an exit.
    const blocks = [_]UniBlock{
        .{ .label = 10, .term = .{ .branch = 11 }, .succs = &.{1} },
        .{ .label = 11, .term = .{ .branch = 12 }, .succs = &.{2} },
        .{ .label = 12, .term = .{ .cond = .{ .cond = 1, .t = 10, .f = 13 } }, .succs = &.{ 0, 3 } },
        .{ .label = 13, .term = .ret, .succs = &.{} },
    };
    var a = try analysisForBlocks(arena, @constCast(&blocks));

    // The diagonal is true: within one block, store/load order is not modelled.
    try std.testing.expect(a.blockReaches(0, 2, 2));
    // Closure THROUGH the back edge: b0 reaches b3 only by going around the
    // loop, and the rows are built from the raw successor graph precisely so
    // a store later in a loop body still reaches an earlier load (the #684
    // may-write filter).
    try std.testing.expect(a.blockReaches(0, 0, 3));
    try std.testing.expect(a.blockReaches(0, 1, 0));
    // No spurious reachability backwards from the exit.
    try std.testing.expect(!a.blockReaches(0, 3, 0));
    try std.testing.expect(!a.blockReaches(0, 3, 1));

    // Unknown answers conservatively TRUE (a may-write filter must count a
    // store it cannot prove irrelevant): out-of-range function, from or to.
    try std.testing.expect(a.blockReaches(9, 0, 0));
    try std.testing.expect(a.blockReaches(0, 99, 0));
    try std.testing.expect(a.blockReaches(0, 0, 99));
}

test "postdominates treats a kill as a dead end, not an exit (probe p20)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // b0 cond -> {b1 kill, b2 -> b3}: every NON-kill path from b0 reaches b3,
    // so b3 postdominates b0 and flow reconverges there. A discard does not
    // poison the following flow; treating the kill as an exit would turn the
    // merge non-uniform and downgrade a huge share of real fragment shaders.
    const kill_blocks = [_]UniBlock{
        .{ .label = 10, .term = .{ .cond = .{ .cond = 1, .t = 11, .f = 12 } }, .succs = &.{ 1, 2 } },
        .{ .label = 11, .term = .kill, .succs = &.{} },
        .{ .label = 12, .term = .{ .branch = 13 }, .succs = &.{3} },
        .{ .label = 13, .term = .ret, .succs = &.{} },
    };
    var kill_a = try analysisForBlocks(arena, @constCast(&kill_blocks));
    try std.testing.expect(kill_a.postdominates(0, 0, 3));

    // Same graph with the kill replaced by an OpReturn: a live path now exits
    // the function avoiding b3, so b3 no longer postdominates b0.
    const ret_blocks = [_]UniBlock{
        .{ .label = 10, .term = .{ .cond = .{ .cond = 1, .t = 11, .f = 12 } }, .succs = &.{ 1, 2 } },
        .{ .label = 11, .term = .ret, .succs = &.{} },
        .{ .label = 12, .term = .{ .branch = 13 }, .succs = &.{3} },
        .{ .label = 13, .term = .ret, .succs = &.{} },
    };
    var ret_a = try analysisForBlocks(arena, @constCast(&ret_blocks));
    try std.testing.expect(!ret_a.postdominates(0, 0, 3));
}
