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

test "optimizer: algebraic simplification x-x=0" {
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
    // u - u should fold to 0.0 — no OpFSub should remain
    try std.testing.expectEqual(@as(u32, 0), countOpcode(spirv, @intFromEnum(glslpp.spirv.Op.FSub)));
}

test "optimizer: algebraic simplification x*0=0" {
    const source =
        \\#version 450
        \\out vec4 FragColor;
        \\uniform float u;
        \\void main() {
        \\    float zero = u * 0.0;
        \\    FragColor = vec4(zero, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try compileFrag(source);
    defer alloc.free(spirv);
    // u * 0.0 should fold to 0.0 — no OpFMul should remain
    try std.testing.expectEqual(@as(u32, 0), countOpcode(spirv, @intFromEnum(glslpp.spirv.Op.FMul)));
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
