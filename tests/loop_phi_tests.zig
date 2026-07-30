// SPDX-License-Identifier: MIT OR Apache-2.0
//! Loop-counter (OpPhi) correctness across the GLSL/HLSL/MSL backends.
//!
//! Regression guard for the silent-wrong bug where a SPIR-V loop-header OpPhi
//! (the loop counter `i`) was rendered as its CONSTANT init value in the
//! GLSL/HLSL/MSL backends — freezing the counter and producing an infinite
//! loop / wrong result. WGSL already handled this correctly. glslang (and
//! spirv-cross, the execution oracle) advance the counter.
//!
//! The check is structural but name-independent: a variable that (transitively)
//! feeds the loop's break condition MUST be re-assigned inside the loop body.
//! In the broken output the counter is never re-assigned (the condition is a
//! loop-invariant comparison against a constant), so the closure is empty.

const std = @import("std");
const zioshade = @import("zioshade");

const alloc = std.testing.allocator;

const COUNTER_LOOP_SRC =
    \\#version 450
    \\out vec4 FragColor;
    \\uniform int n;
    \\uniform float u;
    \\void main() {
    \\    float sum = 0.0;
    \\    for (int i = 0; i < n; i++) { sum += u + float(i); }
    \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
    \\}
;

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

/// Collect identifiers in `expr` into `set`.
fn collectIdents(expr: []const u8, set: *std.StringHashMap(void)) !void {
    var i: usize = 0;
    while (i < expr.len) {
        if (isIdentStart(expr[i])) {
            const start = i;
            while (i < expr.len and isIdentChar(expr[i])) i += 1;
            try set.put(expr[start..i], {});
        } else i += 1;
    }
}

/// Returns the substring of the FIRST `while (true)` loop body (between its
/// opening `{` and the matching `}`), or null.
fn loopBody(src: []const u8) ?[]const u8 {
    const kw = std.mem.indexOf(u8, src, "while (true)") orelse return null;
    // find first '{' after the keyword
    var i = kw;
    while (i < src.len and src[i] != '{') i += 1;
    if (i >= src.len) return null;
    const body_start = i + 1;
    var depth: i32 = 1;
    i = body_start;
    while (i < src.len) : (i += 1) {
        if (src[i] == '{') depth += 1;
        if (src[i] == '}') {
            depth -= 1;
            if (depth == 0) return src[body_start..i];
        }
    }
    return null;
}

/// True if some variable that (transitively, ≤4 levels) feeds the loop's break
/// condition is re-assigned (bare `name = ...;`, not a declaration) inside the
/// loop body. This is the property the fix establishes and the bug violates.
fn loopCounterAdvances(src: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 1) Break condition identifiers: `if (!(COND)) break;`
    const body = loopBody(src) orelse return false;
    const guard = "if (!(";
    const gi = std.mem.indexOf(u8, src, guard) orelse return false;
    const cond_start = gi + guard.len;
    // condition runs until the matching `))` that precedes `break`
    const after = src[cond_start..];
    const brk = std.mem.indexOf(u8, after, "break") orelse return false;
    // trim trailing `)) ` before break
    var cond_end = brk;
    while (cond_end > 0 and (after[cond_end - 1] == ' ' or after[cond_end - 1] == ')')) cond_end -= 1;
    const cond_expr = after[0..cond_end];

    var seeds = std.StringHashMap(void).init(a);
    try collectIdents(cond_expr, &seeds);

    // 2) Declaration map: `<type> name = <rhs>;`  -> rhs identifiers.
    //    Scan whole function (in + outside loop). Last writer wins is fine; we
    //    accumulate all RHS idents per name.
    var decl_deps = std.StringHashMap(std.StringHashMap(void)).init(a);
    // 3) Reassigned-in-loop: bare `name = <rhs>;` statements inside the loop body.
    var reassigned = std.StringHashMap(void).init(a);

    try scanDecls(a, src, &decl_deps);
    try scanBareAssigns(body, &reassigned);

    // 4) Transitive closure of seeds over decl_deps (bounded depth).
    var frontier = std.StringHashMap(void).init(a);
    var iter0 = seeds.iterator();
    while (iter0.next()) |e| try frontier.put(e.key_ptr.*, {});
    var seen = std.StringHashMap(void).init(a);

    var depth: usize = 0;
    while (depth < 6 and frontier.count() > 0) : (depth += 1) {
        var next = std.StringHashMap(void).init(a);
        var it = frontier.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            if (seen.contains(name)) continue;
            try seen.put(name, {});
            if (reassigned.contains(name)) return true;
            if (decl_deps.get(name)) |deps| {
                var di = deps.iterator();
                while (di.next()) |d| try next.put(d.key_ptr.*, {});
            }
        }
        frontier = next;
    }
    return false;
}

/// True if the loop's counter advances on the `continue` path (#237): a variable
/// feeding the break condition is re-assigned BEFORE the first `continue` in the
/// loop body. Returns true vacuously when the loop has no `continue`. In the
/// broken output the only counter write-back is at the BOTTOM (after the
/// `continue`), so a `continue` skips it → infinite loop.
fn continueAdvancesCounter(src: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const body = loopBody(src) orelse return false;
    const cont_pos = std.mem.indexOf(u8, body, "continue") orelse return true; // no continue
    const before = body[0..cont_pos];

    // break-condition seed identifiers
    const guard = "if (!(";
    const gi = std.mem.indexOf(u8, src, guard) orelse return false;
    const after = src[gi + guard.len ..];
    const brk = std.mem.indexOf(u8, after, "break") orelse return false;
    var cond_end = brk;
    while (cond_end > 0 and (after[cond_end - 1] == ' ' or after[cond_end - 1] == ')')) cond_end -= 1;
    var seeds = std.StringHashMap(void).init(a);
    try collectIdents(after[0..cond_end], &seeds);

    var decl_deps = std.StringHashMap(std.StringHashMap(void)).init(a);
    try scanDecls(a, src, &decl_deps);
    var reassigned = std.StringHashMap(void).init(a);
    try scanBareAssigns(before, &reassigned); // ONLY before the first continue

    var frontier = std.StringHashMap(void).init(a);
    var iter0 = seeds.iterator();
    while (iter0.next()) |e| try frontier.put(e.key_ptr.*, {});
    var seen = std.StringHashMap(void).init(a);
    var depth: usize = 0;
    while (depth < 6 and frontier.count() > 0) : (depth += 1) {
        var next = std.StringHashMap(void).init(a);
        var it = frontier.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            if (seen.contains(name)) continue;
            try seen.put(name, {});
            if (reassigned.contains(name)) return true;
            if (decl_deps.get(name)) |deps| {
                var di = deps.iterator();
                while (di.next()) |d| try next.put(d.key_ptr.*, {});
            }
        }
        frontier = next;
    }
    return false;
}

/// Returns {lhs_name, has_type_prefix, rhs_end} for a plain `=` at `src[i]`, or
/// null if it is not a plain assignment LHS.
const AssignLHS = struct { name: []const u8, has_type_prefix: bool };
fn parseAssignAt(src: []const u8, i: usize) ?AssignLHS {
    if (src[i] != '=') return null;
    if (i + 1 < src.len and src[i + 1] == '=') return null;
    if (i > 0 and (src[i - 1] == '=' or src[i - 1] == '<' or src[i - 1] == '>' or src[i - 1] == '!')) return null;
    var j = i;
    while (j > 0 and src[j - 1] == ' ') j -= 1;
    const lhs_end = j;
    while (j > 0 and isIdentChar(src[j - 1])) j -= 1;
    const lhs_start = j;
    if (lhs_end <= lhs_start or !isIdentStart(src[lhs_start])) return null;
    var k = lhs_start;
    while (k > 0 and src[k - 1] == ' ') k -= 1;
    const has_type_prefix = k > 0 and isIdentChar(src[k - 1]);
    return .{ .name = src[lhs_start..lhs_end], .has_type_prefix = has_type_prefix };
}

/// `TYPE name = rhs;`  ->  out[name] += idents(rhs)
fn scanDecls(a: std.mem.Allocator, src: []const u8, out: *std.StringHashMap(std.StringHashMap(void))) !void {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const lhs = parseAssignAt(src, i) orelse continue;
        if (!lhs.has_type_prefix) continue;
        var e = i + 1;
        while (e < src.len and src[e] != ';' and src[e] != '\n') e += 1;
        const gop = try out.getOrPut(lhs.name);
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(a);
        try collectIdents(src[i + 1 .. e], gop.value_ptr);
    }
}

/// bare `name = rhs;` (no type prefix)  ->  out.put(name)
fn scanBareAssigns(src: []const u8, out: *std.StringHashMap(void)) !void {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const lhs = parseAssignAt(src, i) orelse continue;
        if (lhs.has_type_prefix) continue;
        try out.put(lhs.name, {});
    }
}

fn compileToHlsl(source: [:0]const u8) ![]const u8 {
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try zioshade.spirvToHLSL(alloc, spirv, .{ .shader_model = 60 });
}

fn compileToGlsl(source: [:0]const u8) ![]const u8 {
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try zioshade.spirvToGLSL(alloc, spirv, .{});
}

fn compileToMsl(source: [:0]const u8) ![]const u8 {
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try zioshade.spirvToMSL(alloc, spirv, .{});
}

const NESTED_LOOP_SRC =
    \\#version 450
    \\out vec4 FragColor;
    \\uniform int n;
    \\void main() {
    \\    float sum = 0.0;
    \\    for (int i = 0; i < n; i++) {
    \\        for (int j = 0; j < i; j++) { sum += float(i * j); }
    \\    }
    \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
    \\}
;

const DOWHILE_SRC =
    \\#version 450
    \\out vec4 FragColor;
    \\uniform int n;
    \\void main() {
    \\    float s = 0.0;
    \\    int i = 0;
    \\    do { s += float(i); i++; } while (i < n);
    \\    FragColor = vec4(s, 0.0, 0.0, 1.0);
    \\}
;

/// True if a do-while loop was emitted (body not dropped): there is a `while`
/// loop whose body contains a bare assignment (the accumulator/counter update).
/// In the broken output the whole loop + body vanished, so there is no loop.
fn doWhileEmitted(src: []const u8) bool {
    const body = loopBody(src) orelse return false;
    var reassigned = std.StringHashMap(void).init(alloc);
    defer reassigned.deinit();
    scanBareAssigns(body, &reassigned) catch return false;
    return reassigned.count() > 0;
}

const CONTINUE_LOOP_SRC =
    \\#version 450
    \\out vec4 FragColor;
    \\uniform int n;
    \\void main() {
    \\    float s = 0.0;
    \\    for (int i = 0; i < n; i++) { if (i == 3) continue; if (i > 10) break; s += float(i); }
    \\    FragColor = vec4(s, 0.0, 0.0, 1.0);
    \\}
;

// A do-while whose body contains its OWN conditional control flow (`if(i==3) continue;`).
// #244 made all backends honest-error this (it previously crashed GLSL / silently
// miscompiled HLSL/MSL). #246 now emits it faithfully as a native `do { … } while
// (<inlined cond>);` in all three backends — the bottom condition is rebuilt over the
// persistent loop vars so a body `continue` re-evaluates it. See the positive tests below.
const DOWHILE_CF_SRC =
    \\#version 450
    \\out vec4 FragColor;
    \\uniform int n;
    \\void main() {
    \\    float s = 0.0;
    \\    int i = 0;
    \\    do { i++; if (i == 3) continue; s += float(i); } while (i < n);
    \\    FragColor = vec4(s, 0.0, 0.0, 1.0);
    \\}
;

// #246: do-while WITH body control flow is now emitted faithfully in GLSL as a native
// `do { … } while (<inlined cond>);` — the condition is rebuilt over the persistent loop
// vars (so a body `continue` re-evaluates it at the bottom test) rather than a flat-SSA
// temp (which would be out of scope in the C/GLSL do-while controlling expression).
// glslang-validated; semantically n=5 ⇒ s=12 (the i==3 iteration is skipped).
test "do-while with body control flow emits native do/while in GLSL (#246)" {
    const glsl = try compileToGlsl(DOWHILE_CF_SRC);
    defer alloc.free(glsl);
    // Native do-while form, NOT the while(true)+bottom-break rendering.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "do\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "} while (") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "while (true)") == null);
    // The body `continue` survives. The bottom condition is the INLINED comparison over
    // the persistent counter (so a continue re-evaluates it), not a bare SSA temp — the
    // old broken form tested the condition via `if (!(<temp>)) break;`.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "continue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "break;") == null);
}

// #246: HLSL emits do-while-with-body-control-flow as a native `do { … } while (<inlined>);`
// (see the GLSL test above for the rationale). dxc-validated; n=5 ⇒ s=12.
test "do-while with body control flow emits native do/while in HLSL (#246)" {
    const hlsl = try compileToHlsl(DOWHILE_CF_SRC);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "do\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "} while (") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "while (true)") == null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "continue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "break;") == null);
}

// #246: MSL emits do-while-with-body-control-flow as a native `do { … } while (<inlined>);`
// (see the GLSL test above for the rationale). C-like do-while syntax matches the
// dxc/glslang-validated GLSL & HLSL increments.
test "do-while with body control flow emits native do/while in MSL (#246)" {
    const msl = try compileToMsl(DOWHILE_CF_SRC);
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "do\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "} while (") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "while (true)") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "continue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "break;") == null);
}

test "do-while loop body is emitted in HLSL (#238)" {
    const hlsl = try compileToHlsl(DOWHILE_SRC);
    defer alloc.free(hlsl);
    if (!doWhileEmitted(hlsl)) {
        std.debug.print("HLSL dropped the do-while loop body:\n{s}\n", .{hlsl});
        return error.DoWhileBodyDropped;
    }
}

test "continue advances the counter in HLSL (#237)" {
    const hlsl = try compileToHlsl(CONTINUE_LOOP_SRC);
    defer alloc.free(hlsl);
    if (!try continueAdvancesCounter(hlsl)) {
        std.debug.print("HLSL continue skips the counter update (infinite loop):\n{s}\n", .{hlsl});
        return error.ContinueSkipsUpdate;
    }
}

test "loop counter advances in HLSL (phi not frozen)" {
    const hlsl = try compileToHlsl(COUNTER_LOOP_SRC);
    defer alloc.free(hlsl);
    if (!try loopCounterAdvances(hlsl)) {
        std.debug.print("HLSL loop counter is frozen:\n{s}\n", .{hlsl});
        return error.LoopCounterFrozen;
    }
}

// ──────────────────────────────────────────────────────────────────────────
// #loop-continue-deadincr: a Private-var (non-OpPhi) loop counter with a continue
// path must still advance the counter on the continue path. Before the fix the
// increment was emitted at the BOTTOM of the while(true) body, where a body
// `continue;` skipped it -> the counter never advanced -> infinite loop
// (lut_palette et al., maxdiff 255, found via prove_naga on UNOPTIMIZED SPIR-V;
// masked by spirv-opt -O, which lowers to the phi/do-while form). The fix
// generalizes the #237 top-of-loop increment to ALL top-test loops.
//
// zioshade's OWN frontend emits OpPhi loop counters, so the source-compiled tests
// above cannot reach the !has_phis path that was broken. This fixture is
// glslang-produced (Private-var counter, the external-input form) — embedded so the
// test needs no external glslang on PATH.
const PRIVATE_COUNTER_SPV = @embedFile("fixtures/continue_private_counter.spv");

fn crossMsl(spv_bytes: []const u8) ![]const u8 {
    const spv = try wordsFromBytes(spv_bytes);
    defer alloc.free(spv);
    return try zioshade.spirvToMSL(alloc, spv, .{});
}
fn crossGlsl(spv_bytes: []const u8) ![]const u8 {
    const spv = try wordsFromBytes(spv_bytes);
    defer alloc.free(spv);
    return try zioshade.spirvToGLSL(alloc, spv, .{});
}
fn crossHlsl(spv_bytes: []const u8) ![]const u8 {
    const spv = try wordsFromBytes(spv_bytes);
    defer alloc.free(spv);
    return try zioshade.spirvToHLSL(alloc, spv, .{ .shader_model = 60 });
}

/// Reinterpret raw little-endian SPIR-V bytes as u32 words (SPIR-V is a word stream).
/// Copies into an aligned buffer — @embedFile data is byte-aligned, not word-aligned.
fn wordsFromBytes(bytes: []const u8) ![]const u32 {
    std.debug.assert(bytes.len % 4 == 0); // SPIR-V is a whole number of 32-bit words
    const spv = try alloc.alloc(u32, bytes.len / 4);
    @memcpy(std.mem.sliceAsBytes(spv), bytes);
    return spv;
}

test "continue advances a Private-var counter in MSL (#loop-continue-deadincr)" {
    const msl = try crossMsl(PRIVATE_COUNTER_SPV);
    defer alloc.free(msl);
    if (!try continueAdvancesCounter(msl)) {
        std.debug.print("MSL continue skips the Private-var counter update:\n{s}\n", .{msl});
        return error.ContinueSkipsUpdate;
    }
}

test "continue advances a Private-var counter in GLSL (#loop-continue-deadincr)" {
    const glsl = try crossGlsl(PRIVATE_COUNTER_SPV);
    defer alloc.free(glsl);
    if (!try continueAdvancesCounter(glsl)) {
        std.debug.print("GLSL continue skips the Private-var counter update:\n{s}\n", .{glsl});
        return error.ContinueSkipsUpdate;
    }
}

test "continue advances a Private-var counter in HLSL (#loop-continue-deadincr)" {
    const hlsl = try crossHlsl(PRIVATE_COUNTER_SPV);
    defer alloc.free(hlsl);
    if (!try continueAdvancesCounter(hlsl)) {
        std.debug.print("HLSL continue skips the Private-var counter update:\n{s}\n", .{hlsl});
        return error.ContinueSkipsUpdate;
    }
}

fn crossWgsl(spv_bytes: []const u8) ![]const u8 {
    const spv = try wordsFromBytes(spv_bytes);
    defer alloc.free(spv);
    return try zioshade.spirvToWGSL(alloc, spv, .{});
}

// WGSL lowers loops as `loop { }` with a `continuing { }` block (not while(true) +
// _loopfirst), so continueAdvancesCounter (which finds `while (true)`) does not apply.
// The #loop-continue-deadincr fix for WGSL puts the counter increment in `continuing {}`,
// which a body `continue` reaches. Assert that structural signature directly. (A do-while
// counter — continue block ends in a BranchConditional back-edge — must NOT get a
// continuing block; that is covered by wgsl_tests' "do-while counter" naga-validated test.)
test "WGSL puts a Private-var counter increment in continuing{} (#loop-continue-deadincr)" {
    const wgsl = try crossWgsl(PRIVATE_COUNTER_SPV);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "continuing {") != null);
}

// #69: a loop nested inside an if/else BRANCH (here, an else with an early return) was
// silently DROPPED — emitBlock stopped at the else block's OpBranch to the loop header and
// never reached the OpLoopMerge -> emitWhileLoop. glslang-produced fixture (zioshade's own
// frontend can't reach the broken emitBlock path for source-compiled loops). Assert the loop
// survives in the GLSL output.
const LOOP_IN_ELSE_SPV = @embedFile("fixtures/loop_in_else.spv");

test "GLSL emits a loop nested in an else branch (#69)" {
    const glsl = try crossGlsl(LOOP_IN_ELSE_SPV);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "while") != null);
}

// #70: multiple early return points in a function were silently DROPPED — OpReturn skipped
// emitting `return;` for fragment shaders (assumed all returns were final), AND emitBlock
// continued past an early return into the merge block, nesting+duplicating the subsequent
// ifs. The fixture has 3 return paths; assert zioshade-GLSL emits the early returns.
const MULTI_RETURN_SPV = @embedFile("fixtures/multi_return.spv");

test "GLSL emits multiple early return points (#70)" {
    const glsl = try crossGlsl(MULTI_RETURN_SPV);
    defer alloc.free(glsl);
    // 3 return paths in the source (2 early + 1 implicit); at least 2 explicit `return;`
    // must survive (the early ones — the final fall-off needs none).
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, glsl, i, "return;")) |pos| : (count += 1) i = pos + 1;
    try std.testing.expect(count >= 2);
}

// #wgsl-else-clobber: an if/else whose THEN-branch contains a nested (no-else) if was
// silently mis-emitted — opening the nested if overwrote the enclosing if's
// pending_false_label to null, so the enclosing then-block's terminating OpBranch never
// emitted `} else {`. The else-body leaked into the then-branch and the `if` closed late
// at the merge (wrong in BOTH branches). glslang fixture (zioshade's frontend emits the
// same shape). Assert the else clause survives in the WGSL output.
const NESTED_IF_ELSE_SPV = @embedFile("fixtures/nested_if_else.spv");

test "WGSL emits else when then-branch nests an if (#wgsl-else-clobber)" {
    const wgsl = try crossWgsl(NESTED_IF_ELSE_SPV);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "} else {") != null);
}

// #wgsl-loop-in-switch-case: a loop nested inside a switch case body cannot be lowered
// by the limited case-body replay (emitSimpleInstruction has no loop machinery), so it
// was silently DROPPED. zioshade-WGSL now honest-errors instead. GLSL/MSL emit it
// correctly, so this is a WGSL-only gap. This test PINS the honest-error so the path
// cannot silently regress to silent-wrong; if full loop-in-case emission is ever added,
// flip this to assert the loop survives. (Tracked follow-up; revisit if real workloads
// need the construct.)
const LOOP_IN_SWITCH_SPV = @embedFile("fixtures/loop_in_switch.spv");

test "WGSL honest-errors on a loop nested in a switch case (#wgsl-loop-in-switch-case)" {
    try std.testing.expectError(error.UnsupportedLoopInSwitchCase, crossWgsl(LOOP_IN_SWITCH_SPV));
}

test "GLSL still emits a loop nested in a switch case (the construct is valid)" {
    const glsl = try crossGlsl(LOOP_IN_SWITCH_SPV);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "while") != null);
}

// #dowhile-compound-cond (#77): a do-while whose continue block has a nested
// OpSelectionMerge (a short-circuit && / || condition; here forced by abs(), which
// glslang will not fold to OpLogicalAnd) was silently DROPPED by the MSL/GLSL/HLSL
// backends — detectDoWhileBackEdge assumed a single-block continue ending in the
// back-edge. It now follows the nested SelectionMerge to the real back-edge and
// tryInlineDoWhileCond rebuilds the OpPhi-of-bools condition as a faithful ternary
// (polarity-agnostic: correct for both && and ||), so the native do-while emits.
// WGSL also emits the loop correctly. Previously these honest-errored; both the &&
// and || MSL outputs are render-verified pixel-identical to spirv-cross on Metal.
const DOWHILE_COMPOUND_SPV = @embedFile("fixtures/dowhile_compound_cond.spv");
const DOWHILE_COMPOUND_OR_SPV = @embedFile("fixtures/dowhile_compound_cond_or.spv");

// Assert a native do-while whose controlling expression is EXACTLY `expected_cond`.
// Pinning the full ternary (not just survival) catches an arm-swap in
// inlineShortCircuitPhi, which would otherwise emit a plausible-looking but
// semantically-flipped condition (silent miscompile) while every loose check passed.
fn expectDoWhileCond(out: []const u8, expected_cond: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, out, "} while (") != null); // native do-while form
    try std.testing.expect(std.mem.indexOf(u8, out, "while (true)") == null); // not the broken form
    try std.testing.expect(std.mem.indexOf(u8, out, expected_cond) != null); // exact ternary (pins arm order)
}

// `i < 5 && abs(sum) < 0.4` -> the eval block (abs) is the cond-TRUE arm.
test "MSL/GLSL/HLSL emit a do-while with a compound && condition (#77)" {
    const cond = "(i < 5) ? (abs(sum) < 0.4) : (i < 5)";
    const msl = try crossMsl(DOWHILE_COMPOUND_SPV);
    defer alloc.free(msl);
    try expectDoWhileCond(msl, cond);
    const glsl = try crossGlsl(DOWHILE_COMPOUND_SPV);
    defer alloc.free(glsl);
    try expectDoWhileCond(glsl, cond);
    const hlsl = try crossHlsl(DOWHILE_COMPOUND_SPV);
    defer alloc.free(hlsl);
    try expectDoWhileCond(hlsl, cond);
}

// `i < 5 || abs(sum) < 0.4` -> glslang lowers || with a NEGATED router cond
// (`OpBranchConditional !(i<5), eval, merge`), so the eval block (abs) is reached on
// the cond-true path of `!(i<5)`. Exercises the opposite polarity from the && case,
// so the polarity-agnostic claim is actually tested.
test "MSL/GLSL/HLSL emit a do-while with a compound || condition (#77)" {
    const cond = "(!(i < 5)) ? (abs(sum) < 0.4) : (i < 5)";
    const msl = try crossMsl(DOWHILE_COMPOUND_OR_SPV);
    defer alloc.free(msl);
    try expectDoWhileCond(msl, cond);
    const glsl = try crossGlsl(DOWHILE_COMPOUND_OR_SPV);
    defer alloc.free(glsl);
    try expectDoWhileCond(glsl, cond);
    const hlsl = try crossHlsl(DOWHILE_COMPOUND_OR_SPV);
    defer alloc.free(hlsl);
    try expectDoWhileCond(hlsl, cond);
}

test "WGSL still emits a do-while with a compound condition (the construct is valid)" {
    const wgsl = try crossWgsl(DOWHILE_COMPOUND_SPV);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "loop {") != null);
}

/// True if any statement assigns to a NUMERIC-LITERAL left-hand side (e.g.
/// `0 = v19;`), which is invalid output — the broken nested-loop case rendered
/// an unmaterialized phi counter (named after its constant init) as the LHS.
fn assignsToLiteralLHS(src: []const u8) bool {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const lhs = parseAssignAt(src, i) orelse {
            // parseAssignAt rejects non-identifier LHS; detect digit-only LHS here.
            if (src[i] != '=' or (i + 1 < src.len and src[i + 1] == '=')) continue;
            if (i > 0 and (src[i - 1] == '=' or src[i - 1] == '<' or src[i - 1] == '>' or src[i - 1] == '!')) continue;
            var j = i;
            while (j > 0 and src[j - 1] == ' ') j -= 1;
            const end = j;
            while (j > 0 and (src[j - 1] >= '0' and src[j - 1] <= '9')) j -= 1;
            // digit run, and the char before it is not an identifier char
            if (end > j and (j == 0 or !isIdentChar(src[j - 1]))) return true;
            continue;
        };
        _ = lhs;
    }
    return false;
}

test "nested loop counters both advance in HLSL (#phi-loop)" {
    const hlsl = try compileToHlsl(NESTED_LOOP_SRC);
    defer alloc.free(hlsl);
    // The broken nested case emitted `0 = vN;` (assignment to a literal LHS).
    if (assignsToLiteralLHS(hlsl)) {
        std.debug.print("HLSL assigns to a literal LHS (frozen nested phi):\n{s}\n", .{hlsl});
        return error.AssignToLiteral;
    }
    if (!try loopCounterAdvances(hlsl)) {
        std.debug.print("HLSL nested loop counter is frozen:\n{s}\n", .{hlsl});
        return error.LoopCounterFrozen;
    }
}

test "do-while loop body is emitted in GLSL (#238)" {
    const glsl = try compileToGlsl(DOWHILE_SRC);
    defer alloc.free(glsl);
    if (!doWhileEmitted(glsl)) {
        std.debug.print("GLSL dropped the do-while loop body:\n{s}\n", .{glsl});
        return error.DoWhileBodyDropped;
    }
}

test "do-while loop body is emitted in MSL (#238)" {
    const msl = try compileToMsl(DOWHILE_SRC);
    defer alloc.free(msl);
    if (!doWhileEmitted(msl)) {
        std.debug.print("MSL dropped the do-while loop body:\n{s}\n", .{msl});
        return error.DoWhileBodyDropped;
    }
}

test "continue advances the counter in GLSL (#237)" {
    const glsl = try compileToGlsl(CONTINUE_LOOP_SRC);
    defer alloc.free(glsl);
    if (!try continueAdvancesCounter(glsl)) {
        std.debug.print("GLSL continue skips the counter update (infinite loop):\n{s}\n", .{glsl});
        return error.ContinueSkipsUpdate;
    }
}

test "continue advances the counter in MSL (#237)" {
    const msl = try compileToMsl(CONTINUE_LOOP_SRC);
    defer alloc.free(msl);
    if (!try continueAdvancesCounter(msl)) {
        std.debug.print("MSL continue skips the counter update (infinite loop):\n{s}\n", .{msl});
        return error.ContinueSkipsUpdate;
    }
}

test "loop counter advances in GLSL (phi not frozen)" {
    const glsl = try compileToGlsl(COUNTER_LOOP_SRC);
    defer alloc.free(glsl);
    if (!try loopCounterAdvances(glsl)) {
        std.debug.print("GLSL loop counter is frozen:\n{s}\n", .{glsl});
        return error.LoopCounterFrozen;
    }
}

test "nested loop counters both advance in GLSL (#phi-loop)" {
    const glsl = try compileToGlsl(NESTED_LOOP_SRC);
    defer alloc.free(glsl);
    if (assignsToLiteralLHS(glsl)) {
        std.debug.print("GLSL assigns to a literal LHS (frozen nested phi):\n{s}\n", .{glsl});
        return error.AssignToLiteral;
    }
    if (!try loopCounterAdvances(glsl)) {
        std.debug.print("GLSL nested loop counter is frozen:\n{s}\n", .{glsl});
        return error.LoopCounterFrozen;
    }
}

test "loop counter advances in MSL (phi not frozen)" {
    const msl = try compileToMsl(COUNTER_LOOP_SRC);
    defer alloc.free(msl);
    if (!try loopCounterAdvances(msl)) {
        std.debug.print("MSL loop counter is frozen:\n{s}\n", .{msl});
        return error.LoopCounterFrozen;
    }
}

test "nested loop counters both advance in MSL (#phi-loop)" {
    const msl = try compileToMsl(NESTED_LOOP_SRC);
    defer alloc.free(msl);
    if (assignsToLiteralLHS(msl)) {
        std.debug.print("MSL assigns to a literal LHS (frozen nested phi):\n{s}\n", .{msl});
        return error.AssignToLiteral;
    }
    if (!try loopCounterAdvances(msl)) {
        std.debug.print("MSL nested loop counter is frozen:\n{s}\n", .{msl});
        return error.LoopCounterFrozen;
    }
}

// ---------------------------------------------------------------------------
// SubpassData (Vulkan input attachments): glslang lowers `subpassLoad(x)` to an
// OpImageRead whose coordinate is a (0,0) placeholder (the read is implicitly at
// the fragment position in Vulkan). Metal has NO implicit subpass reads, so the
// MSL must read at the threaded fragment coordinate (`uint2(_fragCoord.xy)`), NOT
// at (0,0) (which would make every fragment sample the top-left pixel). Fixture is
// glslang-produced (zioshade's own frontend does not parse Vulkan `subpassInput`).
// ---------------------------------------------------------------------------
const SUBPASS_INPUT_SPV = @embedFile("fixtures/subpass_input.spv");

test "subpassInput OpImageRead reads at the fragment coordinate, not (0,0)" {
    const msl = try crossMsl(SUBPASS_INPUT_SPV);
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "read(uint2(_fragCoord") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "read(uint2(int2(0)))") == null);
}

// Multisampled input attachments (subpassInputMS) need texture2d_ms + a per-sample
// read, which this backend defers; honest-error (refuse) rather than emit a non-MS
// read that silently samples the wrong pixel. glslang-produced fixture.
const SUBPASS_INPUT_MS_SPV = @embedFile("fixtures/subpass_input_ms.spv");

test "subpassInputMS honest-errors (MS texture-type modeling deferred)" {
    try std.testing.expectError(error.UnsupportedMultisampledSubpassInput, crossMsl(SUBPASS_INPUT_MS_SPV));
}

// WGSL port of the same SubpassData fix (#488). WGSL has no implicit subpass read
// either, so a subpassLoad's OpImageRead (Dim 6) must read at the fragment
// coordinate (@builtin(position)), not at the (0,0) placeholder. The source SPIR-V
// does not declare gl_FragCoord (subpassLoad never names it), so the WGSL backend
// synthesizes a @builtin(position) input. The texture is read-only (a writable
// storage texture is rejected by naga in fragment stage).
test "WGSL subpassInput reads at the fragment coordinate, not (0,0)" {
    const wgsl = try crossWgsl(SUBPASS_INPUT_SPV);
    defer alloc.free(wgsl);
    // A @builtin(position) input is synthesized and the read is at its .xy.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@builtin(position) _fragCoord") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vec2<i32>(_fragCoord.xy)") != null);
    // The old (0,0) placeholder read must be gone.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vec2<i32>(0)") == null);
    // The subpass texture is read-only (read_write is a naga reject in fragment).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ", read>") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ", read_write>") == null);
}

// WGSL likewise defers MS subpass reads (no multisampled storage texture form); the
// OpImageRead arm honest-errors via the storageImageShape multisample guard.
test "WGSL subpassInputMS honest-errors (MS storage texture deferred)" {
    try std.testing.expectError(error.UnsupportedOp, crossWgsl(SUBPASS_INPUT_MS_SPV));
}

// ---------------------------------------------------------------------------
// #for-loop-init (#482 MSL port): no use-before-declaration in a no-OpPhi loop
// ---------------------------------------------------------------------------

/// Assert no SSA temp (`v<digits>`) is referenced textually before the statement
/// that declares it. A declaration site is an occurrence whose previous token is
/// another identifier (its type); statement keywords are excluded so `return v5;`
/// counts as a use. Ported from glsl_tests.zig (#413).
fn assertNoUseBeforeDecl(src: []const u8) !void {
    const keywords = [_][]const u8{ "return", "else", "if", "while", "for", "do", "case", "in", "out", "inout", "const", "break", "continue", "discard" };
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }
    var i: usize = 0;
    while (i < src.len) {
        if (!(std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
        const tok = src[i..j];
        const start = i;
        i = j;
        if (tok.len < 2 or tok[0] != 'v') continue;
        var all_digits = true;
        for (tok[1..]) |ch| {
            if (!std.ascii.isDigit(ch)) {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) continue;
        var k = start;
        while (k > 0 and (src[k - 1] == ' ' or src[k - 1] == '\t')) k -= 1;
        var is_decl = false;
        if (k > 0 and (std.ascii.isAlphanumeric(src[k - 1]) or src[k - 1] == '_')) {
            var t0 = k;
            while (t0 > 0 and (std.ascii.isAlphanumeric(src[t0 - 1]) or src[t0 - 1] == '_')) t0 -= 1;
            const prev = src[t0..k];
            is_decl = true;
            for (keywords) |kw| {
                if (std.mem.eql(u8, prev, kw)) {
                    is_decl = false;
                    break;
                }
            }
        }
        if (is_decl and seen.contains(tok)) {
            std.debug.print("#for-loop-init: `{s}` is referenced before its declaration in output:\n{s}\n", .{ tok, src });
            return error.UseBeforeDeclaration;
        }
        if (!seen.contains(tok)) {
            const dup = try alloc.dupe(u8, tok);
            try seen.put(dup, {});
        }
    }
}

// #for-loop-init (#482 MSL port): a loop whose counter is a Private/Function
// var (NOT an OpPhi), present when the counter is used PAST the loop, has its
// continue block hoisted to the top of the while-body inside `if (!_loopfirst)`.
// The continue reads the header's OpLoad of the counter (e.g. `v25 + 1`), but
// that OpLoad was emitted in the body AFTER the if-block -> the if-block reads
// it before its declaration -> Metal rejects ("use of undeclared identifier
// 'v25'"). GLSL/HLSL were fixed in #482 (carried-phi/header-load hoist); MSL's
// #413 pass only covered phi update ids and skipped phi-less loops. The fix
// ports the header-load hoist to MSL. zioshade's own frontend reaches the
// no-phi path for a counter used past the loop (it stays a Function var).
const FOR_LOOP_INIT_COUNTER_USED_AFTER_SRC =
    \\#version 310 es
    \\precision mediump float;
    \\layout(location = 0) out int FragColor;
    \\void main()
    \\{
    \\   FragColor = 16;
    \\   int k = 0;
    \\   for (; k < 20; k++)
    \\      FragColor += 12;
    \\   k += 3;
    \\   FragColor += k;
    \\}
;

test "MSL: no-OpPhi Function-counter loop has no use-before-declaration (#for-loop-init, #482 MSL port)" {
    const msl = try compileToMsl(FOR_LOOP_INIT_COUNTER_USED_AFTER_SRC);
    defer alloc.free(msl);
    // The loop must be present (sanity: we reached the loop-lowering path).
    try std.testing.expect(std.mem.indexOf(u8, msl, "while (true)") != null);
    // The continue-hoist's if-block must not read a temp declared later in the
    // body. Buggy output declares the header OpLoad temp inside the body after
    // the if-block reads it (Metal: "use of undeclared identifier").
    assertNoUseBeforeDecl(msl) catch |err| {
        std.debug.print("MSL for-loop-init output has a use-before-declaration:\n{s}\n", .{msl});
        return err;
    };
}

test "GLSL: no-OpPhi Function-counter loop has no use-before-declaration (#for-loop-init)" {
    const glsl = try compileToGlsl(FOR_LOOP_INIT_COUNTER_USED_AFTER_SRC);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "while (true)") != null);
    assertNoUseBeforeDecl(glsl) catch |err| {
        std.debug.print("GLSL for-loop-init output has a use-before-declaration:\n{s}\n", .{glsl});
        return err;
    };
}
