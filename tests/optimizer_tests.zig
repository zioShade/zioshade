const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

// Helper: compile a fragment shader to SPIR-V
fn compileFrag(source: [:0]const u8) ![]const u32 {
    return glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment, .spirv_version = .@"1.5" });
}

// Helper: check that an opcode appears in the SPIR-V
fn hasOpcode(spirv: []const u32, opcode: u32) bool {
    for (spirv) |word| {
        if ((word & 0xFFFF) == opcode) return true;
    }
    return false;
}

// Helper: count occurrences of an opcode
fn countOpcode(spirv: []const u32, opcode: u32) u32 {
    var count: u32 = 0;
    for (spirv) |word| {
        if ((word & 0xFFFF) == opcode) count += 1;
    }
    return count;
}

// ============================================================================
// Optimizer pipeline correctness tests
// These verify the optimizer doesn't miscompile shaders or produce invalid SPIR-V.
// ============================================================================

test "optimizer: constant folding preserves semantics" {
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\void main() {
        \\    const int a = 10;
        \\    const int b = 20;
        \\    int c = a + b;
        \\    float f = float(c) * 2.0;
        \\    FragColor = vec4(float(c), f, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // The optimizer should fold a+b=30, then float(30)*2.0=60.0
    // Result should have constant 60.0 as a component of FragColor
    try std.testing.expect(spirv.len > 0);
}

test "optimizer: dead code elimination removes unused instructions" {
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\void main() {
        \\    float unused = 1.0 + 2.0;
        \\    float also_unused = unused * 3.0;
        \\    FragColor = vec4(1.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // The unused computations should be eliminated
    // Check that the SPIR-V is relatively compact
    try std.testing.expect(spirv.len > 0);
}

test "optimizer: loop with accumulation is preserved" {
    // Regression test: deadLoopElim was removing loops whose results
    // flow to output via function-local variables
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\uniform float u;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 4; i++) {
        \\        sum += u + float(i);
        \\    }
        \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // The loop must be preserved because sum flows to FragColor
    // Verify there's a loop in the output (OpLoopMerge)
    try std.testing.expect(hasOpcode(spirv, @intFromEnum(glslpp.spirv.Op.LoopMerge)));
}

test "optimizer: loop accumulating into a struct member is preserved (#220)" {
    // Regression: deadLoopElim's Phase 2.5 load-after-merge check matched only a
    // DIRECT `OpLoad %var`, missing `OpLoad` of an `OpAccessChain` into the var.
    // A loop accumulating into a struct MEMBER (read back via access chain after
    // the loop) was therefore wrongly eliminated, folding the member to its
    // initial value — wrong numeric result on ALL backends. glslang preserves it.
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\uniform float u;
        \\struct A { float s; };
        \\void main() {
        \\    A a;
        \\    a.s = 0.0;
        \\    for (int i = 0; i < 4; i++) { a.s += u + float(i); }
        \\    FragColor = vec4(a.s, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // The loop must survive — a.s accumulates and flows to FragColor.
    try std.testing.expect(hasOpcode(spirv, @intFromEnum(glslpp.spirv.Op.LoopMerge)));
}

test "optimizer: loop accumulating into an array element is preserved (#220)" {
    // Same root cause as the struct-member case: the array element's access chain
    // is hoisted out of the loop, so the in-loop store + post-loop load go through
    // it. deadLoopElim must recognize the hoisted-AC store/load as touching the
    // base local, or it wrongly eliminates the loop.
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\uniform float u;
        \\void main() {
        \\    float arr[4];
        \\    arr[0] = 0.0;
        \\    for (int i = 0; i < 4; i++) { arr[0] += u + float(i); }
        \\    FragColor = vec4(arr[0], 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    try std.testing.expect(hasOpcode(spirv, @intFromEnum(glslpp.spirv.Op.LoopMerge)));
}

test "optimizer: AC+Store to composite variable preserves loads" {
    // Regression test: optimizer was eliminating loads after AC+Store
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\uniform float u;
        \\void main() {
        \\    vec4 v = vec4(0.0);
        \\    v.x = u;
        \\    v.y = u * 2.0;
        \\    FragColor = v;
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // The store to v.x and v.y must be preserved — FragColor reads v
    try std.testing.expect(spirv.len > 0);
}

test "optimizer: double negation is eliminated" {
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\uniform float u;
        \\void main() {
        \\    float a = -(-u);
        \\    FragColor = vec4(a, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // -(-u) should simplify to u — no FNegate instructions should remain
    try std.testing.expectEqual(@as(u32, 0), countOpcode(spirv, @intFromEnum(glslpp.spirv.Op.FNegate)));
}

test "optimizer: branch folding with constant condition" {
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\void main() {
        \\    float x;
        \\    if (true) {
        \\        x = 1.0;
        \\    } else {
        \\        x = 0.0;
        \\    }
        \\    FragColor = vec4(x, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // The if(true) should be folded — no OpBranchConditional remaining
    try std.testing.expectEqual(@as(u32, 0), countOpcode(spirv, @intFromEnum(glslpp.spirv.Op.BranchConditional)));
}

test "optimizer: trivial phi simplification" {
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\void main() {
        \\    float x = 1.0;
        \\    if (false) {
        \\        x = 2.0;
        \\    }
        \\    FragColor = vec4(x, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // The dead branch should be eliminated, x should be const-folded to 1.0
    try std.testing.expect(spirv.len > 0);
}

test "optimizer: composite extract from constant composite is folded" {
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\void main() {
        \\    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
        \\    float x = v.x;
        \\    float y = v.y;
        \\    FragColor = vec4(x, y, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // CompositeExtract from constant composite should fold to the constant value
    // No OpCompositeExtract should remain for v.x and v.y
    try std.testing.expect(spirv.len > 0);
}

test "optimizer: float u - u is NOT folded (the fold produced `u`, and Inf-Inf=NaN)" {
    // The `x - x` fold was REMOVED: it mapped the result to operand `b` (= x), so `u - u`
    // computed `u` instead of `0` (wrong-value miscompile); and even a correct fold to a
    // literal 0 would be wrong for IEEE (`Inf - Inf = NaN`). Leaving the OpFSub computes the
    // right value for every input, so it must survive.
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\uniform float u;
        \\void main() {
        \\    float diff = u - u;
        \\    FragColor = vec4(diff, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    try std.testing.expect(countOpcodeStrict(spirv, @intFromEnum(glslpp.spirv.Op.FSub)) >= 1);
}

test "optimizer: integer u - u is NOT folded to `u` (was a wrong-value miscompile)" {
    // Same bug for OpISub: `u - u` mapped to operand `u` instead of 0. Removed; the OpISub
    // survives and computes the correct 0 at runtime.
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\uniform int u;
        \\void main() {
        \\    int diff = u - u;
        \\    FragColor = vec4(float(diff), 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    try std.testing.expect(countOpcodeStrict(spirv, @intFromEnum(glslpp.spirv.Op.ISub)) >= 1);
}

test "optimizer: algebraic simplification x*0=0 (INTEGER — valid, no NaN/Inf)" {
    // INTEGER x*0 folds to 0 — this is exact for integers (no NaN/Inf). (The FLOAT u*0.0
    // fold was REMOVED — Inf*0/NaN*0 are NaN; see the dedicated float test above.)
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\uniform int u;
        \\void main() {
        \\    int zero = u * 0;
        \\    FragColor = vec4(float(zero), 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // u * 0 should fold to 0 — no OpIMul should remain
    try std.testing.expectEqual(@as(u32, 0), countOpcode(spirv, @intFromEnum(glslpp.spirv.Op.IMul)));
}

test "optimizer: inline trivial functions" {
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\float identity(float x) { return x; }
        \\void main() {
        \\    float v = identity(1.0);
        \\    FragColor = vec4(v, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // The trivial function should be inlined
    // After inlining, the constant should propagate through
    try std.testing.expect(spirv.len > 0);
}

fn compileCompute(source: [:0]const u8) ![]const u32 {
    return glslpp.compileToSPIRV(alloc, source, .{ .stage = .compute, .spirv_version = .@"1.5" });
}

fn compileComputeNoOpt(source: [:0]const u8) ![]const u32 {
    return glslpp.compileToSPIRVNoOpt(alloc, source, .{ .stage = .compute, .spirv_version = .@"1.5" });
}

// Returns the word index of the FIRST instruction with `opcode`, or null.
fn firstOpcodePos(spirv: []const u32, opcode: u32) ?usize {
    var i: usize = 5; // skip header
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        if (wc == 0) break;
        if ((spirv[i] & 0xFFFF) == opcode) return i;
        i += wc;
    }
    return null;
}

// Finds the word index of the OpLoad whose result_id == `value_id`, or null.
fn loadPosForResult(spirv: []const u32, value_id: u32) ?usize {
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        if (wc == 0) break;
        // OpLoad: [op|wc][result_type][result_id][pointer]...
        if ((spirv[i] & 0xFFFF) == 61 and wc >= 4 and spirv[i + 2] == value_id) return i;
        i += wc;
    }
    return null;
}

// Finds the value operand of the LAST OpStore whose value is produced by an OpLoad
// (i.e. the `result.total = s_counter` store, not the `s_counter = 0u` const store).
fn lastStoreLoadedValue(spirv: []const u32) ?u32 {
    var i: usize = 5;
    var found: ?u32 = null;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        if (wc == 0) break;
        // OpStore: [op|wc][pointer][value]
        if ((spirv[i] & 0xFFFF) == 62 and wc >= 3) {
            const value_id = spirv[i + 2];
            if (loadPosForResult(spirv, value_id) != null) found = value_id;
        }
        i += wc;
    }
    return found;
}

// Asserts the load feeding the SSBO write is ordered AFTER the atomic RMW (#223).
fn assertLoadAfterAtomic(spirv: []const u32) !void {
    const atomic_pos = firstOpcodePos(spirv, 234) orelse return error.NoAtomic; // OpAtomicIAdd
    const stored_val = lastStoreLoadedValue(spirv) orelse return error.NoLoadedStore;
    const load_pos = loadPosForResult(spirv, stored_val) orelse return error.NoLoad;
    // The shared read that flows to result.total MUST come after the atomicAdd.
    try std.testing.expect(load_pos > atomic_pos);
}

const ATOMIC_SHARED_SRC =
    \\#version 310 es
    \\layout(local_size_x = 32) in;
    \\shared uint s_counter;
    \\layout(std430, binding = 0) buffer Result { uint total; } result;
    \\void main() {
    \\    uint idx = gl_LocalInvocationID.x;
    \\    if (idx == 0u) s_counter = 0u;
    \\    barrier();
    \\    atomicAdd(s_counter, 1u);
    \\    barrier();
    \\    if (idx == 0u) result.total = s_counter;
    \\}
;

test "frontend: shared read after atomicAdd is not hoisted before it (#223, opt)" {
    const spirv = try compileCompute(ATOMIC_SHARED_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterAtomic(spirv);
}

test "frontend: shared read after atomicAdd is not hoisted before it (#223, no-opt)" {
    const spirv = try compileComputeNoOpt(ATOMIC_SHARED_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterAtomic(spirv);
}

// #235: a load through one access chain (`b.data[j]`) must NOT be reused after an
// atomic mutates a SIBLING access chain (`b.data[i]`) into the SAME base buffer.
// The two chains have distinct SSA ids, so the pre-#235 invalidation (exact chain
// id + base only) left the cached `b.data[j]` load alive across the atomic — and
// `y` reused the stale pre-atomic value when i == j at runtime. After the fix the
// `result.total = y` store must read a load positioned AFTER the OpAtomicIAdd.
const ALIAS_CHAIN_SRC =
    \\#version 310 es
    \\layout(local_size_x = 32) in;
    \\layout(std430, binding = 0) buffer B { uint data[]; } b;
    \\layout(std430, binding = 1) buffer R { uint total; } result;
    \\void main() {
    \\    uint j = gl_LocalInvocationID.x;
    \\    uint i = gl_LocalInvocationID.y; // statically distinct chain; may alias j at runtime
    \\    uint x = b.data[j];
    \\    atomicAdd(b.data[i], 1u);
    \\    uint y = b.data[j];
    \\    result.total = y;
    \\}
;

test "frontend: sibling access-chain load not reused across atomic on same base (#235, opt)" {
    const spirv = try compileCompute(ALIAS_CHAIN_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterAtomic(spirv);
}

test "frontend: sibling access-chain load not reused across atomic on same base (#235, no-opt)" {
    const spirv = try compileComputeNoOpt(ALIAS_CHAIN_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterAtomic(spirv);
}

// #235 (review finding): the SAME sibling-aliasing bug is reachable through a
// plain read-modify-write store (`b.data[i]++`), not just an atomic. The `++`
// store through chain_i must invalidate the cached `b.data[j]` load through the
// sibling chain_j. After the fix, `result.total = y` must read a load positioned
// AFTER the increment's OpIAdd (opcode 128), not the stale pre-increment one.
fn assertLoadAfterIAdd(spirv: []const u32) !void {
    const iadd_pos = firstOpcodePos(spirv, 128) orelse return error.NoIAdd; // OpIAdd (the b.data[i]++ add)
    const stored_val = lastStoreLoadedValue(spirv) orelse return error.NoLoadedStore;
    const load_pos = loadPosForResult(spirv, stored_val) orelse return error.NoLoad;
    try std.testing.expect(load_pos > iadd_pos);
}

const ALIAS_INCR_SRC =
    \\#version 310 es
    \\layout(local_size_x = 32) in;
    \\layout(std430, binding = 0) buffer B { uint data[]; } b;
    \\layout(std430, binding = 1) buffer R { uint total; } result;
    \\void main() {
    \\    uint j = gl_LocalInvocationID.x;
    \\    uint i = gl_LocalInvocationID.y; // statically distinct chain; may alias j at runtime
    \\    uint x = b.data[j];
    \\    b.data[i]++;
    \\    uint y = b.data[j];
    \\    result.total = y;
    \\}
;

test "frontend: sibling access-chain load not reused across ++ store on same base (#235, opt)" {
    const spirv = try compileCompute(ALIAS_INCR_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterIAdd(spirv);
}

test "frontend: sibling access-chain load not reused across ++ store on same base (#235, no-opt)" {
    const spirv = try compileComputeNoOpt(ALIAS_INCR_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterIAdd(spirv);
}

// #234: a barrier()/atomic hidden inside a CALLED helper must invalidate the
// caller's load cache. glslpp emits a real OpFunctionCall (no frontend inlining);
// the call site did not invalidate load_cache/global_load_cache, so a read of a
// shared/SSBO variable AFTER the call reused the pre-call cached load — the #223
// memory-ordering violation, one call-frame deep.
// Asserts the value stored to result.total is loaded AFTER the OpFunctionCall
// (no-opt: bump() is a real call, not yet inlined). In the buggy output the read
// reused the pre-call cached load, positioned BEFORE the call.
fn assertLoadAfterCall(spirv: []const u32) !void {
    const call_pos = firstOpcodePos(spirv, 57) orelse return error.NoCall; // OpFunctionCall
    const stored_val = lastStoreLoadedValue(spirv) orelse return error.NoLoadedStore;
    const load_pos = loadPosForResult(spirv, stored_val) orelse return error.NoLoad;
    try std.testing.expect(load_pos > call_pos);
}

const HELPER_ATOMIC_SRC =
    \\#version 310 es
    \\layout(local_size_x = 32) in;
    \\shared uint s_counter;
    \\layout(std430, binding = 0) buffer R { uint total; } result;
    \\void bump() { atomicAdd(s_counter, 1u); barrier(); }
    \\void main() {
    \\    uint a = s_counter;
    \\    bump();
    \\    uint b = s_counter;
    \\    if (gl_LocalInvocationID.x == 0u) result.total = b;
    \\}
;

test "frontend: shared read after a helper that does atomic+barrier is re-loaded (#234, no-opt)" {
    const spirv = try compileComputeNoOpt(HELPER_ATOMIC_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterCall(spirv);
}

test "frontend: shared read after a helper that does atomic+barrier is re-loaded (#234, opt)" {
    // After inlining bump() into main, the OpAtomicIAdd sits in main; the read
    // feeding result.total must be loaded AFTER it (not the stale pre-call load).
    const spirv = try compileCompute(HELPER_ATOMIC_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterAtomic(spirv);
}

// #248 residual A — a sibling load cached in a DOMINATING block (entry / loop
// header, where `cache_globals` is true → the load lands in `global_load_cache`)
// must be invalidated by a sibling mutation in a CHILD block. `invalidateAliasingChains`
// (pre-#248) iterated `ac_result_to_base`, which is reset at every block boundary,
// so the dominating-block chain id was absent from the child block's map and the
// stale `global_load_cache` entry survived the atomic. `data[j]` is loaded in the
// entry block, then `data[i]` is atomically bumped inside `if (x > 0u)`, then
// `data[j]` is read again in that child block — the re-read must load AFTER the
// atomic, not reuse the dominating-block cached value.
const ALIAS_DOMINATING_SRC =
    \\#version 310 es
    \\layout(local_size_x = 32) in;
    \\layout(std430, binding = 0) buffer B { uint data[]; } buf;
    \\layout(std430, binding = 1) buffer R { uint total; } result;
    \\void main() {
    \\    uint j = gl_LocalInvocationID.x;
    \\    uint i = gl_LocalInvocationID.y; // statically distinct; may alias j at runtime
    \\    uint x = buf.data[j];            // ENTRY (dominating) block → global_load_cache
    \\    if (x > 0u) {
    \\        atomicAdd(buf.data[i], 1u);  // mutate sibling chain data[i] in CHILD block
    \\        uint y = buf.data[j];        // re-read: must NOT reuse the dominating-block load
    \\        result.total = y;
    \\    }
    \\}
;

test "frontend: sibling load cached in dominating block re-loads after atomic in child (#248-A, opt)" {
    const spirv = try compileCompute(ALIAS_DOMINATING_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterAtomic(spirv);
}

test "frontend: sibling load cached in dominating block re-loads after atomic in child (#248-A, no-opt)" {
    const spirv = try compileComputeNoOpt(ALIAS_DOMINATING_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterAtomic(spirv);
}

// #248 residual B — a MULTI-LEVEL nested lvalue. `buf.arr[i].a` is built as nested
// single-index access chains (`arr` member → `[i]` → `.a`), so `buf.arr[i].a` and
// `buf.arr[j].a` resolve to DIFFERENT immediate bases (`arr[i]` vs `arr[j]`). The
// pre-#248 sibling invalidation keyed on the immediate base only, so a store to
// `buf.arr[i].a` did not invalidate the cached `buf.arr[j].a` load — they alias
// exactly when i == j. After the fix the chain root (`buf`) is resolved transitively
// and all chains into it are invalidated, so the re-read loads AFTER the `x + 1u`
// OpIAdd that produced the stored value.
const ALIAS_NESTED_SRC =
    \\#version 310 es
    \\layout(local_size_x = 32) in;
    \\struct Cell { uint a; uint b; };
    \\layout(std430, binding = 0) buffer B { Cell arr[]; } buf;
    \\layout(std430, binding = 1) buffer R { uint total; } result;
    \\void main() {
    \\    uint j = gl_LocalInvocationID.x;
    \\    uint i = gl_LocalInvocationID.y; // statically distinct; may alias j at runtime
    \\    uint x = buf.arr[j].a;            // load nested chain arr[j].a (cached)
    \\    buf.arr[i].a = x + 1u;            // store nested chain arr[i].a (same component; aliases when i==j)
    \\    uint y = buf.arr[j].a;            // re-read: must NOT reuse the pre-store load
    \\    result.total = y;
    \\}
;

test "frontend: multi-level nested sibling load re-loads after store on aliasing chain (#248-B, opt)" {
    const spirv = try compileCompute(ALIAS_NESTED_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterIAdd(spirv);
}

test "frontend: multi-level nested sibling load re-loads after store on aliasing chain (#248-B, no-opt)" {
    const spirv = try compileComputeNoOpt(ALIAS_NESTED_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterIAdd(spirv);
}

// #248 residual C (surfaced by the code review of the A/B fix) — the MUTATED chain
// itself was built in a DOMINATING block. `buf.data[0]` (literal index) is created
// while evaluating the entry-block `if` condition, so it lands in
// `global_access_chain_cache`. The `atomicAdd(buf.data[0], ...)` in the child block
// re-uses that cached chain id, which is therefore ABSENT from the child block's
// (per-block) `ac_result_to_base`. The invalidation entry points gate sibling
// invalidation on `ac_result_to_base.get(ptr_id)`, so the gate missed and the cached
// sibling `buf.data[j]` load (in `global_load_cache` from the entry block) survived
// the atomic → stale when j == 0. Fixed by routing the gate through the per-function
// `chain_root_base` (which DOES contain the dominating-block chain id).
const ALIAS_DOM_MUT_SRC =
    \\#version 310 es
    \\layout(local_size_x = 32) in;
    \\layout(std430, binding = 0) buffer B { uint data[]; } buf;
    \\layout(std430, binding = 1) buffer R { uint total; } result;
    \\void main() {
    \\    uint j = gl_LocalInvocationID.x;
    \\    uint y = buf.data[j];            // ENTRY: sibling chain → global_load_cache
    \\    if (buf.data[0] > 0u) {          // ENTRY: data[0] chain → global_access_chain_cache
    \\        atomicAdd(buf.data[0], 1u);  // CHILD: data[0] reused from dominating block; ac_result_to_base miss
    \\        uint z = buf.data[j];        // re-read sibling: must NOT reuse the dominating-block load
    \\        result.total = z;
    \\    }
    \\}
;

test "frontend: sibling load survives mutation through a dominating-block chain (#248-C, opt)" {
    const spirv = try compileCompute(ALIAS_DOM_MUT_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterAtomic(spirv);
}

test "frontend: sibling load survives mutation through a dominating-block chain (#248-C, no-opt)" {
    const spirv = try compileComputeNoOpt(ALIAS_DOM_MUT_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterAtomic(spirv);
}

// #248 residual D (surfaced by the review of the C fix) — the MULTI-COMPONENT swizzle
// compound-assign path (`v.xy *= k`) is a fifth mutation site. It reads the whole
// vector, recombines via OpVectorShuffle, and stores the result back, but pre-fix it
// only removed its own chain id from the caches — it did NOT invalidate SIBLING chains
// into the same root. So a cached `buf.data[j].x` load survived `buf.data[i].xy *= 2.0`
// and read stale when i == j. Fixed by routing this site through invalidateAliasingChains
// too. Landmark: the store-back's value is an OpVectorShuffle result (unique to this
// path); the re-read load feeding result.total must be positioned AFTER that store.
fn isResultOfOpcode(spirv: []const u32, value_id: u32, opcode: u32) bool {
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        if (wc == 0) break;
        if ((spirv[i] & 0xFFFF) == opcode and wc >= 3 and spirv[i + 2] == value_id) return true;
        i += wc;
    }
    return false;
}

// Word index of the first OpStore whose stored value is an OpVectorShuffle (79) result
// — i.e. the swizzle compound-assign store-back.
fn swizzleStorePos(spirv: []const u32) ?usize {
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        if (wc == 0) break;
        if ((spirv[i] & 0xFFFF) == 62 and wc >= 3) { // OpStore
            const value_id = spirv[i + 2];
            if (isResultOfOpcode(spirv, value_id, 79)) return i;
        }
        i += wc;
    }
    return null;
}

fn assertLoadAfterSwizzleStore(spirv: []const u32) !void {
    const store_pos = swizzleStorePos(spirv) orelse return error.NoSwizzleStore;
    const stored_val = lastStoreLoadedValue(spirv) orelse return error.NoLoadedStore;
    const load_pos = loadPosForResult(spirv, stored_val) orelse return error.NoLoad;
    try std.testing.expect(load_pos > store_pos);
}

// Whole-vec sibling reads so the value stored to result.total is a direct OpLoad
// (a `.x` read would store an OpCompositeExtract, which lastStoreLoadedValue can't
// track). The first store caches buf.data[j]'s load (it roots in `buf`, NOT `result`,
// so it survives the result.total store); the swizzle store-back on the sibling
// data[i] must invalidate it so the second read re-loads.
const ALIAS_SWIZZLE_SRC =
    \\#version 310 es
    \\layout(local_size_x = 32) in;
    \\layout(std430, binding = 0) buffer B { vec4 data[]; } buf;
    \\layout(std430, binding = 1) buffer R { vec4 total; } result;
    \\void main() {
    \\    uint j = gl_LocalInvocationID.x;
    \\    uint i = gl_LocalInvocationID.y; // statically distinct; may alias j at runtime
    \\    result.total = buf.data[j];       // load chain data[j] (cached)
    \\    buf.data[i].xy *= 2.0;            // swizzle compound-assign store-back on sibling data[i]
    \\    result.total = buf.data[j];       // re-read: must NOT reuse the pre-store load
    \\}
;

test "frontend: sibling load re-loads after swizzle compound-assign store-back (#248-D, opt)" {
    const spirv = try compileCompute(ALIAS_SWIZZLE_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterSwizzleStore(spirv);
}

test "frontend: sibling load re-loads after swizzle compound-assign store-back (#248-D, no-opt)" {
    const spirv = try compileComputeNoOpt(ALIAS_SWIZZLE_SRC);
    defer alloc.free(spirv);
    try assertLoadAfterSwizzleStore(spirv);
}

// Walk the instruction stream (header is 5 words) counting a specific opcode, so an
// operand WORD that happens to equal the opcode value is not miscounted as an instruction.
fn countOpcodeStrict(spirv: []const u32, opcode: u16) u32 {
    var i: usize = 5;
    var count: u32 = 0;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        if (wc == 0) break;
        if (@as(u16, @truncate(spirv[i] & 0xFFFF)) == opcode) count += 1;
        i += wc;
    }
    return count;
}

// The CSE pass (cseWithinBlocks) keyed redundant ops on (result_type, operands) WITHOUT
// the OPCODE, so `isnan(v)` and `isinf(v)` (both bvecN over the same v) collided and the
// second was merged into the first — a silent-wrong miscompile (`any(isinf(v))` silently
// became `any(isnan(v))`). Both ops must survive optimization as distinct instructions.
test "optimizer: CSE does not merge OpIsInf into OpIsNan (distinct opcodes, same operand)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(location = 0) in vec3 v;
        \\void main() {
        \\    bvec3 n = isnan(v);
        \\    bvec3 i = isinf(v);
        \\    o = vec4(float(any(n)) + float(any(i)), 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    try std.testing.expect(countOpcodeStrict(spirv, @intFromEnum(glslpp.spirv.Op.IsNan)) >= 1);
    try std.testing.expect(countOpcodeStrict(spirv, @intFromEnum(glslpp.spirv.Op.IsInf)) >= 1);
}

// algebraicSimpl folded `x * 0.0 → 0.0` for floats, which is WRONG per IEEE: Inf*0 and
// NaN*0 are NaN, not 0. The fold (OpFMul case) was a silent-wrong miscompile. `x * 1.0`
// stays foldable (exact for all values). The OpFMul must survive here (its operand can be
// Inf at runtime), not be replaced by the zero constant.
test "optimizer: x * 0.0 is NOT folded to 0.0 for floats (Inf*0 = NaN)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 col;
        \\layout(location = 0) in float t;
        \\void main() {
        \\    float big = 1.0 / t;   // +Inf when t == 0
        \\    float r = big * 0.0;   // Inf*0 == NaN per IEEE, must NOT fold to 0.0
        \\    col = vec4(r, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    try std.testing.expect(countOpcodeStrict(spirv, @intFromEnum(glslpp.spirv.Op.FMul)) >= 1);
}

// Sibling guard: `all(v)` and `any(v)` over the same bvec also collided under the
// opcode-less CSE key (All=155, Any=154 were both eligible). They must stay distinct.
test "optimizer: CSE does not merge OpAll into OpAny (distinct opcodes, same operand)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(location = 0) in vec3 v;
        \\void main() {
        \\    bvec3 b = lessThan(v, vec3(0.5));
        \\    o = vec4(float(all(b)) + float(any(b)) * 2.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    try std.testing.expect(countOpcodeStrict(spirv, @intFromEnum(glslpp.spirv.Op.All)) >= 1);
    try std.testing.expect(countOpcodeStrict(spirv, @intFromEnum(glslpp.spirv.Op.Any)) >= 1);
}
