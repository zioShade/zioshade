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

/// Returns the substring of the FIRST loop body (between its opening `{` and the
/// matching `}`), or null. Matches GLSL/HLSL/MSL `while (true)` first, then WGSL
/// `loop {` (only WGSL emits `loop {`; `while (true)` is tried first so the other
/// backends are unaffected).
fn loopBody(src: []const u8) ?[]const u8 {
    const kw = std.mem.indexOf(u8, src, "while (true)") orelse
        (std.mem.indexOf(u8, src, "loop {") orelse return null);
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

/// True if every variable read on the RHS of a loop-top carry copy
/// (`if (!_loopfirst...) { vA = vB; }`, the #413/#237 back-edge carrier read) is itself
/// bare-assigned somewhere in the loop body. Guards the #phi-carrier silent-wrong
/// (PR #579): a loop-carried OpPhi whose back-edge update is a selection-merge OpPhi
/// (the Collatz step `x = (x & 1) ? 3*x+1 : x/2` in graphicsfuzz_002) had its carrier
/// read at loop top but only a disconnected `vN_phi` temp written in the body, leaving
/// the carrier uninitialized. The GLSL frontend lowers loop counters to Function vars,
/// so external OpPhi SPIR-V is the only way to reach the path.
fn loopCarriersAssigned(src: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const body = loopBody(src) orelse return true; // no while(true)/loop{} -> vacuous
    const lf = std.mem.indexOf(u8, body, "_loopfirst") orelse return true; // no carry block
    var bi = lf;
    while (bi < body.len and body[bi] != '{') bi += 1;
    if (bi >= body.len) return true;
    const carry_start = bi + 1;
    var depth: i32 = 1;
    var ce = carry_start;
    while (ce < body.len) : (ce += 1) {
        if (body[ce] == '{') depth += 1;
        if (body[ce] == '}') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    if (depth != 0) return true;
    const carry = body[carry_start..ce];

    // carriers = RHS identifiers of bare `vA = vB;` copies inside the carry block
    var carriers = std.StringHashMap(void).init(a);
    var i: usize = 0;
    while (i < carry.len) : (i += 1) {
        if (parseAssignAt(carry, i) == null) continue;
        var e = i + 1;
        while (e < carry.len and carry[e] != ';') e += 1;
        try collectIdents(carry[i + 1 .. e], &carriers);
    }

    var assigned = std.StringHashMap(void).init(a);
    try scanBareAssigns(body, &assigned);

    var it = carriers.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.*.len > 0 and !assigned.contains(e.key_ptr.*)) return false;
    }
    return true;
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

// #switch-case-continue: a switch case whose body branches to the enclosing
// LOOP's continue target must emit `continue;`, not `break;`. zioshade emitted
// `break` (switch break) so the post-switch code ran on the continue path ->
// silent-wrong (loop-dominator-and-switch-default; a clean repro adds ~100x per
// iteration). The fix extends g_loop_merge_ctx with the loop's continue label and
// emits `continue` in emitBlock for an OpBranch to it. Fixture is deterministic
// (gl_FragCoord-derived input, no UB, no uniform).
const SWITCH_CASE_CONTINUE_SPV = @embedFile("fixtures/switch_case_continue.spv");

test "GLSL continues the outer loop from a switch case (#switch-case-continue)" {
    const glsl = try crossGlsl(SWITCH_CASE_CONTINUE_SPV);
    defer alloc.free(glsl);
    const di = std.mem.indexOf(u8, glsl, "default:") orelse return error.MissingDefault;
    if (std.mem.indexOf(u8, glsl[di..], "continue;") == null) {
        std.debug.print("GLSL switch default does not continue the outer loop:\n{s}\n", .{glsl});
        return error.SwitchCaseNotContinued;
    }
}

// #switch-case-continue (MSL): the MSL twin of the above. MSL's LoopMergeCtx lacked
// a continue_label (GLSL #584, WGSL, and HLSL all had one), so an OpBranch to the
// enclosing loop's continue (e.g. `if (c) continue;` inside a switch case) was
// DROPPED -- the if-body emitted empty -> the continue never fired -> silent-wrong.
// Fixture is a deterministic conditional-continue inside a switch default.
const SWITCH_CASE_CONTINUE_MSL_SPV = @embedFile("fixtures/switch_case_continue_msl.spv");

test "MSL continues the outer loop from a switch case (#switch-case-continue)" {
    const msl = try crossMsl(SWITCH_CASE_CONTINUE_MSL_SPV);
    defer alloc.free(msl);
    if (std.mem.indexOf(u8, msl, "continue;") == null) {
        std.debug.print("MSL drops the loop continue from the switch case:\n{s}\n", .{msl});
        return error.MslSwitchCaseContinueDropped;
    }
}

// #switch-case-continue (HLSL): the HLSL twin. HLSL's LoopInfo already tracked the
// continue label (`.cont`) but emitBlock (the branch-arm emitter) didn't act on a
// Branch to it, so the arm body emitted empty -> the continue was dropped ->
// silent-wrong. Same fix shape as GLSL #584 / MSL #586.
const SWITCH_CASE_CONTINUE_HLSL_SPV = @embedFile("fixtures/switch_case_continue_hlsl.spv");

test "HLSL continues the outer loop from a switch case (#switch-case-continue)" {
    const hlsl = try crossHlsl(SWITCH_CASE_CONTINUE_HLSL_SPV);
    defer alloc.free(hlsl);
    if (std.mem.indexOf(u8, hlsl, "continue;") == null) {
        std.debug.print("HLSL drops the loop continue from the switch case:\n{s}\n", .{hlsl});
        return error.HlslSwitchCaseContinueDropped;
    }
}

// #switch-case-continue (WGSL): the last backend of the family. The comment on the
// GLSL test above says WGSL already had a continue label -- it does TRACK one, but
// neither switch case-body walker ever consulted it. Both walkers stop at the first
// terminator and DISCARD it, which is right for a branch to the switch's merge (WGSL
// cases do not fall through) and wrong for a branch to the loop's continue target.
// All three fixtures reproduce it; naga ACCEPTS the output either way, so this is
// silent-wrong rather than a validity failure. Assert on the default arm specifically:
// a bare search for "continue;" would not be fooled by the `continuing` block, but
// pinning the arm is what actually distinguishes the fix.
test "WGSL continues the outer loop from a switch case (#switch-case-continue)" {
    for ([_][]const u8{
        SWITCH_CASE_CONTINUE_SPV,
        SWITCH_CASE_CONTINUE_MSL_SPV,
        SWITCH_CASE_CONTINUE_HLSL_SPV,
    }) |spv| {
        const wgsl = try crossWgsl(spv);
        defer alloc.free(wgsl);
        const di = std.mem.indexOf(u8, wgsl, "default:") orelse return error.MissingDefault;
        if (std.mem.indexOf(u8, wgsl[di..], "continue;") == null) {
            std.debug.print("WGSL switch default does not continue the outer loop:\n{s}\n", .{wgsl});
            return error.WgslSwitchCaseContinueDropped;
        }
    }
}

// #phi-carrier (PR #579): a loop-carried OpPhi whose back-edge update is itself a
// selection-merge OpPhi (the Collatz step `x = (x & 1) ? 3*x+1 : x/2` in
// graphicsfuzz_002). zioshade hoists the carrier above the loop (#413) and the loop-top
// carry reads it, so the body selection MUST write the carrier -- not a disconnected
// `vN_phi` temp that leaves it uninitialized (silent-wrong). The GLSL frontend lowers loop
// counters to Function vars, so this external-OpPhi SPIR-V shape is the only way to reach
// the path. Fixture is tests/cts/graphicsfuzz/graphicsfuzz_002.spv.
const PHI_CARRIER_SPV = @embedFile("fixtures/phi_carrier_collatz.spv");

test "GLSL assigns a loop carrier updated by a selection (#phi-carrier)" {
    const glsl = try crossGlsl(PHI_CARRIER_SPV);
    defer alloc.free(glsl);
    if (!try loopCarriersAssigned(glsl)) {
        std.debug.print("GLSL leaves a loop-top carry carrier unassigned:\n{s}\n", .{glsl});
        return error.LoopCarrierUnassigned;
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

// #pattern-b-loop-in-arm: a loop nested in a selection arm whose header computes the exit
// condition IN-HEADER (OpPhi; <cond>; OpLoopMerge; OpBranchConditional -- the "Pattern B"
// shape zioshade's OWN frontend emits for `for`) was silently DROPPED, along with every
// instruction after it in the arm. The #69 follow-branch check in emitBlock detected a loop
// header by skipping header Phis and demanding an OpLoopMerge immediately after; the
// in-header condition sits between them, so the check failed and emitBlock broke at the
// OpBranch. glslang lowers the same source to Pattern A (condition in a separate block), so
// the #69 fixture above missed this. Fixture compiled by zioshade's own frontend -- the
// exact shape the structural-drop sweep flags on loop_in_case/early_return2/for-loop-init
// and 8 CTS shaders. Assert the loop survives.
const PATB_LOOP_IN_ARM_SPV = @embedFile("fixtures/patb_loop_in_arm.spv");

test "GLSL emits a Pattern-B loop nested in a selection arm (#pattern-b-loop-in-arm)" {
    const glsl = try crossGlsl(PATB_LOOP_IN_ARM_SPV);
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

// #selfloop: OpLoopMerge %merge %hdr where the continue target IS the loop header
// (the body sits in the header before the LoopMerge -- a self-loop). zioshade REFUSED
// this (emitWhileLoop self-reentered on the header's own LoopMerge -> CrossCompileUnsupported)
// while spirv-cross lowers it as `for(;;){ body; if(!cond) break; advance }`. The naive
// "break the self-recursion" guard is silent-wrong (double body + counter reset -> infinite
// loop). Assert zioshade now emits a TERMINATING loop whose phi counter advances (no
// counter-reset / infinite-loop silent-wrong), structured as while(true) + if(!(cond))break.
// Render-MATCH vs spirv-cross (outColor = 55,55,55,1) is verified via
// tools/glsl_render_check_spv.sh.
const SELFLOOP_BODYHEADER_SPV = @embedFile("fixtures/selfloop_bodyheader.spv");

test "GLSL lowers a self-loop with body-in-header (#selfloop)" {
    const glsl = try crossGlsl(SELFLOOP_BODYHEADER_SPV);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "while (true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "if (!(") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "break;") != null);
    if (!try loopCounterAdvances(glsl)) {
        std.debug.print("GLSL self-loop never advances the counter (infinite loop):\n{s}\n", .{glsl});
        return error.SelfLoopDoesNotAdvance;
    }
}

// HLSL used to CRASH (SIGSEGV, exit 139) on the self-loop (emitWhileLoopHLSL re-entered
// the header's own LoopMerge with no recursion bound -> stack overflow), then honest-
// errored once the recursion guard landed. It now LOWERS it via the HLSL twin of
// emitSelfLoopBodyHeader{GLSL,MSL}. Assert a terminating while(true) loop whose counter
// advances. (The recursion guard remains for non-self-loop pathological nesting; the
// crash history is why it stays.) DXC/glslang-validity + the HLSL gate verify separately.
test "HLSL lowers a self-loop with body-in-header (#selfloop)" {
    const hlsl = try crossHlsl(SELFLOOP_BODYHEADER_SPV);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "while (true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "if (!(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "break;") != null);
    if (!try loopCounterAdvances(hlsl)) {
        std.debug.print("HLSL self-loop never advances the counter (infinite loop):\n{s}\n", .{hlsl});
        return error.SelfLoopDoesNotAdvance;
    }
}

// #hlsl-selfloop-in-arm: a self-loop (continue target IS its header) nested in a selection
// ARM was silently DROPPED by HLSL. emitBlock's #switch-case-continue check (an OpBranch to
// any tracked loop's continue -> `continue;`) runs BEFORE the nested-loop entry, and a self-
// loop's continue IS its header, so an OpBranch that ENTERS the self-loop matched the continue
// check and emitted a bare `continue;`, dropping the whole loop. GLSL is unaffected (its
// continue check uses only the innermost loop's continue). The top-level #selfloop fixture
// above is reached via emitBody, so it missed this emitBlock path. Fixture: a self-loop nested
// in an if-arm (spirv-as, vulkan1.2). Assert HLSL emits the loop.
const SELFLOOP_IN_ARM_SPV = @embedFile("fixtures/selfloop_in_arm.spv");

test "HLSL emits a self-loop nested in a selection arm (#hlsl-selfloop-in-arm)" {
    const hlsl = try crossHlsl(SELFLOOP_IN_ARM_SPV);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "while (true)") != null);
}

// WGSL used to emit BROKEN code (exit 0) on the self-loop: the loop-header phi's
// back-edge predecessor IS the header (same block, before the phi), so the index-based
// init/update attribution misread the back-edge incoming as the init
// (`let v = <not-yet-defined increment>` -> naga "no definition in scope"), AND the
// `continuing {}` scan (which looks for the continue label after the LoopMerge) found
// nothing for cont==header, so the phi update never emitted -> the counter never
// advanced -> infinite loop. Now: correct attribution (pred==header -> update) + emit
// the phi update after the back-edge break. Assert a terminating loop whose counter
// advances. naga-validity is verified separately (tools + the wgsl gate).
test "WGSL lowers a self-loop with body-in-header (#selfloop)" {
    const wgsl = try crossWgsl(SELFLOOP_BODYHEADER_SPV);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "loop {") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "if (!(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "break;") != null);
    if (!try loopCounterAdvances(wgsl)) {
        std.debug.print("WGSL self-loop never advances the counter (infinite loop):\n{s}\n", .{wgsl});
        return error.SelfLoopDoesNotAdvance;
    }
}

// MSL used to honest-error (UnsupportedOpcode) on the self-loop. It now lowers it via
// the MSL twin of emitSelfLoopBodyHeaderGLSL. Assert a terminating while(true) loop
// whose counter advances. Metal-validity + render-MATCH vs spirv-cross are verified
// via the MSL validity gate + prove_opt (render-diff on Metal).
test "MSL lowers a self-loop with body-in-header (#selfloop)" {
    const msl = try crossMsl(SELFLOOP_BODYHEADER_SPV);
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "while (true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "if (!(") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "break;") != null);
    if (!try loopCounterAdvances(msl)) {
        std.debug.print("MSL self-loop never advances the counter (infinite loop):\n{s}\n", .{msl});
        return error.SelfLoopDoesNotAdvance;
    }
}

// Reversed-polarity twin of SELFLOOP_BODYHEADER_SPV (back-edge BranchConditional targets
// swapped: true->merge=break, false->header=continue; cond negated so semantics are
// identical, acc = 55). spirv-cross lowers it; zioshade honest-errors it in ALL backends:
// the normal-polarity exit path is the only place the self-loop phi back-edge update is
// emitted, so a reversed back-edge would silently drop it -> the counter never advances
// -> infinite loop (valid output, oracle-accepted = silent-wrong). GLSL/MSL guard via
// back-edge polarity; WGSL + HLSL guard on the self-loop shape. This locks the honest-
// error so it cannot regress to silent-wrong (the hole PR #544 review found in WGSL).
const SELFLOOP_REVERSED_SPV = @embedFile("fixtures/selfloop_reversed.spv");

test "all backends honest-error a reversed-polarity self-loop (#selfloop)" {
    try std.testing.expectError(error.CrossCompileUnsupported, crossGlsl(SELFLOOP_REVERSED_SPV));
    try std.testing.expectError(error.CrossCompileUnsupported, crossMsl(SELFLOOP_REVERSED_SPV));
    try std.testing.expectError(error.CrossCompileUnsupported, crossWgsl(SELFLOOP_REVERSED_SPV));
    try std.testing.expectError(error.CrossCompileUnsupported, crossHlsl(SELFLOOP_REVERSED_SPV));
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

// ── #loop-in-selection-arm ────────────────────────────────────────────────
//
// A loop nested in a SELECTION arm (an `if`/`else` body or a switch case) was
// dropped whole by the GLSL backend, together with every statement after it in
// that arm. The output still compiled, so no validity gate could see it.
//
// emitBlock followed an OpBranch into a loop header only when the OpLoopMerge
// sat immediately after the header's leading OpPhis. That is glslang's shape
// (Pattern A: the header branches to a separate condition block). zioshade's
// OWN frontend emits Pattern B, computing the loop condition IN the header:
//
//     %15 = OpLabel
//     %19 = OpPhi %int %int_0 %11 %24 %17
//     %20 = OpSLessThan %bool %19 %int_3     <-- blocked the phi-only scan
//           OpLoopMerge %18 %17 None
//
// so the branch read as end-of-arm and the loop never reached emitWhileLoop.
//
// These tests drive the frontend on purpose. tools/glsl_faithfulness.sh cannot
// catch this class: it re-lowers the source through glslangValidator, which
// only ever produces Pattern A.

const LOOP_IN_IF_SRC =
    \\#version 450
    \\out vec4 FragColor;
    \\void main() {
    \\    float s = 0.0;
    \\    if (gl_FragCoord.x < 10.0) {
    \\        for (int i = 0; i < 3; i++) { s += float(i); }
    \\        s += 100.0;
    \\    }
    \\    FragColor = vec4(s, 0.0, 0.0, 1.0);
    \\}
;

const LOOP_IN_SWITCH_CASE_SRC =
    \\#version 450
    \\out vec4 FragColor;
    \\void main() {
    \\    int sel = int(gl_FragCoord.x) % 3;
    \\    int outv = 0;
    \\    switch (sel) {
    \\        case 0:
    \\            for (int i = 0; i < 3; i++) { outv += i; }
    \\            outv += 7;
    \\            break;
    \\        default:
    \\            outv = 200;
    \\            break;
    \\    }
    \\    FragColor = vec4(float(outv), 0.0, 0.0, 1.0);
    \\}
;

test "GLSL: a loop in an if arm is not dropped (#loop-in-selection-arm)" {
    const glsl = try compileToGlsl(LOOP_IN_IF_SRC);
    defer alloc.free(glsl);
    if (std.mem.indexOf(u8, glsl, "while (true)") == null) {
        std.debug.print("GLSL dropped the loop nested in the if arm:\n{s}\n", .{glsl});
        return error.LoopDropped;
    }
    // The statement AFTER the loop shares the loop's fate: dropping the loop
    // ended the arm, so `s += 100.0` vanished too.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "100.0") != null);
}

test "GLSL: a loop in a switch case body is not dropped (#loop-in-selection-arm)" {
    const glsl = try compileToGlsl(LOOP_IN_SWITCH_CASE_SRC);
    defer alloc.free(glsl);
    if (std.mem.indexOf(u8, glsl, "while (true)") == null) {
        std.debug.print("GLSL dropped the loop nested in the switch case:\n{s}\n", .{glsl});
        return error.LoopDropped;
    }
    // Buggy output was `case 0: { break; }` -- the loop AND the trailing add
    // gone, while the untouched default case still emitted its assignment.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "7") != null);
}

test "MSL agrees: the same loops survive in the reference backend" {
    const a = try compileToMsl(LOOP_IN_IF_SRC);
    defer alloc.free(a);
    const b = try compileToMsl(LOOP_IN_SWITCH_CASE_SRC);
    defer alloc.free(b);
    try std.testing.expect(std.mem.indexOf(u8, a, "while (true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "while (true)") != null);
}

// ── #loop-break-arm-double-emit ───────────────────────────────────────────
//
// A loop body containing an early `if (cond) break;` emitted the correct
// conditional break AND THEN a second, unconditional `break;`, which made the
// entire rest of the loop body unreachable. A plain counting loop accumulated
// nothing.
//
// The break lowers to a selection whose arm block holds only `OpBranch <loop
// merge>`. The BranchConditional handler emits the whole `if (cond) { break; }`
// from the branch alone, but did not advance past that arm block, so the main
// walker reached it and #loop-break-on-selection-merge emitted the break again.
//
// naga accepts unreachable code, so no validity gate saw it, and the structural
// -drop sweep counts loops rather than reachability. 36 of 1468 corpus shaders
// were affected: every mandelbrot, ray-march and search-loop in the corpus.

const LOOP_EARLY_BREAK_SRC =
    \\#version 450
    \\out vec4 FragColor;
    \\void main() {
    \\    float acc = 0.0;
    \\    for (int i = 0; i < 10; i++) {
    \\        if (float(i) > gl_FragCoord.x) { break; }
    \\        acc += 1.0;
    \\    }
    \\    FragColor = vec4(acc, 0.0, 0.0, 1.0);
    \\}
;

fn compileToWgsl(source: [:0]const u8) ![]const u8 {
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try zioshade.spirvToWGSL(alloc, spirv, .{});
}

/// Any statement following a statement-level `break;` in the same block is
/// unreachable. `continuing {` does not count: it is part of the enclosing
/// `loop` construct rather than a statement, and it legitimately follows a
/// break.
fn assertNoStatementAfterBreak(src: []const u8) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    var pending_indent: ?usize = null;
    while (it.next()) |raw| {
        // Only `std.mem.trim` is spelled the same on both 0.15.2 and 0.16, so the
        // indent is counted by hand rather than via a trimLeft/trimStart pair.
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        var indent: usize = 0;
        while (indent < raw.len and (raw[indent] == ' ' or raw[indent] == '\t')) indent += 1;
        if (pending_indent) |bi| {
            pending_indent = null;
            if (indent >= bi and
                !std.mem.startsWith(u8, trimmed, "}") and
                !std.mem.startsWith(u8, trimmed, "continuing"))
            {
                std.debug.print("unreachable statement after break: `{s}`\n", .{trimmed});
                return error.UnreachableAfterBreak;
            }
        }
        if (std.mem.eql(u8, trimmed, "break;")) pending_indent = indent;
    }
}

test "WGSL: an early break does not orphan the rest of the loop body (#loop-break-arm-double-emit)" {
    const wgsl = try compileToWgsl(LOOP_EARLY_BREAK_SRC);
    defer alloc.free(wgsl);
    assertNoStatementAfterBreak(wgsl) catch |err| {
        std.debug.print("WGSL:\n{s}\n", .{wgsl});
        return err;
    };
    // The accumulate must survive: it is the statement the spurious break orphaned.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "+ 1.0f") != null);
}

test "the other backends agree the body is live" {
    const g = try compileToGlsl(LOOP_EARLY_BREAK_SRC);
    defer alloc.free(g);
    const m = try compileToMsl(LOOP_EARLY_BREAK_SRC);
    defer alloc.free(m);
    try std.testing.expect(std.mem.indexOf(u8, g, "+ 1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "+ 1.0") != null);
}

// ── #selection-merge-not-a-trampoline ─────────────────────────────────────
//
// A selection's own MERGE block was classified as a break/continue trampoline
// whenever it went on to branch to the loop's continue or merge label. That is
// just what the block after an `if` does, so the classification inverted the
// selection: the arm that should have been guarded got emitted unconditionally,
// and the continue block's instructions were replayed inline in the body.
//
// Where the loop has a `continuing { }` block the two forms happen to agree, so
// 47 corpus shaders only got simpler. graphicsfuzz_061 has no continuing block,
// and there the inline replay landed AFTER an unconditional `return`: the loop's
// `canwalk` exit test could never run, the loop had no exit at all, and the
// black path after it was dead. naga puts that test in `continuing { break if }`.
//
// The invariant asserted here is the one that distinguishes the two forms: a
// loop whose only early exit is a `return` needs no `continue;` at all. The
// pre-fix binary emits one, together with a duplicate of the continuing block's
// increment.

const RETURN_IN_LOOP_SRC =
    \\#version 450
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 0) out vec4 fragColor;
    \\void main() {
    \\    for (int i = 0; i < 10; i++) {
    \\        if (uv.x > 0.9) {
    \\            fragColor = vec4(1.0, 0.0, 0.0, 1.0);
    \\            return;
    \\        }
    \\    }
    \\    fragColor = vec4(0.0, 0.0, 1.0, 1.0);
    \\}
;

test "WGSL: a loop whose only early exit is a return needs no continue (#selection-merge-not-a-trampoline)" {
    const wgsl = try compileToWgsl(RETURN_IN_LOOP_SRC);
    defer alloc.free(wgsl);
    // The guarded arm must hold the return, not be inverted around it.
    if (std.mem.indexOf(u8, wgsl, "continue;") != null) {
        std.debug.print("WGSL inverted the selection and emitted a continue:\n{s}\n", .{wgsl});
        return error.SelectionInverted;
    }
    // And the early return must still be there, inside a guard.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "return") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "1.0, 0.0, 0.0") != null);
}

// #body-is-continue: a Pattern-B loop whose BranchConditional body-target IS the
// continue label (one block serving as both — `for (i=3; i>=0; i--) a[i] -= x;`)
// was emitted TWICE per iteration: the _loopfirst carry replay re-executed the
// block at the while-top AND the body walk emitted it again after the break. For
// pure bodies the recomputation is discarded (benign); for a STORING body the
// replay re-reads post-store state and compounds the effect — each `a[i] -= x`
// applied twice (graphicsfuzz_084's back-substitution loops; found by the CTS
// faithfulness sweep + two-way isolation, the last real candidate of the 9).
// The prologue now emits only the phi assignments. Assert the store line appears
// exactly once inside the while body.
const BODY_IS_CONTINUE_STORE_SPV = @embedFile("fixtures/body_is_continue_store.spv");

test "GLSL emits a body-is-continue store loop once per iteration (#body-is-continue)" {
    const glsl = try crossGlsl(BODY_IS_CONTINUE_STORE_SPV);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "while") != null);
    // The read-modify-write store must appear exactly ONCE in the whole function
    // (twice = the double-execution bug).
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, glsl, i, "= v21;")) |pos| : (count += 1) i = pos + 1;
    try std.testing.expect(count == 1);

    // VALIDITY (review C1): the prologue's carry copy (`v17 = v22;`) references
    // the phi-update temp, whose only declaration must therefore come BEFORE the
    // `while` (the #413 hoist), not textually below the copy inside the loop --
    // a below-declaration is a use-before-declaration compile error.
    const prologue_use = std.mem.indexOf(u8, glsl, "v17 = v22;") orelse return error.TestUnexpectedFind;
    try std.testing.expect(std.mem.indexOf(u8, glsl[0..prologue_use], "int v22") != null);
}

// #switch-arm-break: an if-arm inside a switch case whose OpBranch targets the
// SWITCH's merge (a break out of the switch from inside a selection — _021's
// `if (c) { <phi assignment>; break; }` early-exit) was emitted as an EMPTY arm:
// the walker ended at the OpBranch without emitting the switch-merge phi copy or
// `break;`, so the early-exit never fired and the phi kept the wrong value on
// that path — silent-wrong, compiles clean (graphicsfuzz_021's round-trip renders
// differ on all 4096 pixels). MSL already had the mechanism (g_switch_ctx +
// per-pred phi copy + break); this ports it to GLSL.
const SWITCH_ARM_BREAK_SPV = @embedFile("fixtures/switch_arm_break.spv");

test "GLSL emits a selection arm's break out of the enclosing switch (#switch-arm-break)" {
    const glsl = try crossGlsl(SWITCH_ARM_BREAK_SPV);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "switch") != null);
    // The early-exit arm (`if (v17)`) must NOT be empty: it must carry the
    // switch-merge phi copy and the `break;`. (A bare break-count assertion
    // passes spuriously — other breaks exist elsewhere in the function.)
    const empty_arm = "if (v17)\n        {\n        }";
    if (std.mem.indexOf(u8, glsl, empty_arm)) |_| {
        std.debug.print("empty early-exit arm in output:\n{s}\n", .{glsl});
        return error.TestEmptyEarlyExitArm;
    }
    // And the arm's break must exist right after the phi copy: find `if (v17)`
    // and require a `break;` between it and the next `vec2` decl (the arm's
    // successor statement in this fixture).
    const ifpos = std.mem.indexOf(u8, glsl, "if (v17)") orelse return error.TestUnexpectedFind;
    const window = glsl[ifpos..@min(ifpos + 200, glsl.len)];
    try std.testing.expect(std.mem.indexOf(u8, window, "break;") != null);
    // FALL-THROUGH edge: the default's terminal branch to the switch merge must
    // copy the merge phi for ITS OWN block (the case entry label does not match
    // on multi-block cases) — `v41_phi = v40_phi;` before the trailing break.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "v41_phi = v40_phi;") != null);
}

// #latch-phi: a continue-block phi (latch phi) whose value differs per incoming
// path (`v83_phi = v42` on the if-continue arm, `= v183_phi_phi` on the fall-
// through) got NO copies anywhere: the loop walker's trivial-continue fast path
// emitted a bare `if (c) continue;` and its branch-to-continue skip dropped the
// rest silently. The loop-header carry then read an UNINITIALIZED variable every
// iteration (graphicsfuzz_003: all three accumulators diverged in the round-trip
// render). The live instance of the TODO(latch-phi) documented since #586.
// Assert the latch phi is WRITTEN on both paths of the tail selection.
const LATCH_PHI_CONTINUE_SPV = @embedFile("fixtures/latch_phi_continue.spv");

test "GLSL writes the latch phi on both paths of a tail continue (#latch-phi)" {
    const glsl = try crossGlsl(LATCH_PHI_CONTINUE_SPV);
    defer alloc.free(glsl);
    // The continue arm's copy and the fall-through's copy must BOTH exist.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "v186_phi = v42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "v186_phi = v183_phi_phi;") != null);
}

// #third-switch-site: a switch nested in a SELECTION ARM is emitted by emitBlock's own
// OpSwitch handler -- the third GLSL switch site (emitBody and emitWhileLoop are the
// other two, both ctx-wired by #611). That third site never materialized switch-merge
// phis: it emitted bare `case N:` labels, jumped past the merge block, and the generic
// OpPhi walker then refused the merge phi (UnsupportedPhiAlias) -- loud, but a construct
// MSL already lowers correctly (it wires all three sites). Port of MSL's third-site
// shape: phi decls before the switch + SwitchCtxGLSL + per-case copies. Fixture: an
// if-arm containing a switch whose merge phi selects a different constant per case;
// the outer merge phi carries the value out (spirv-as, vulkan1.0).
const SWITCH_IN_ARM_PHI_SPV = @embedFile("fixtures/switch_in_arm_phi.spv");

test "GLSL materializes switch-merge phis for a switch in a selection arm (#third-switch-site)" {
    const glsl = try crossGlsl(SWITCH_IN_ARM_PHI_SPV);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "switch (") != null);
    // The switch-merge phi must be declared before the switch and assigned per case
    // (a `_phi;` decl + copies naming all three distinct case constants).
    const sw = std.mem.indexOf(u8, glsl, "switch (").?;
    const decl_before = std.mem.lastIndexOf(u8, glsl[0..sw], "_phi;");
    try std.testing.expect(decl_before != null);
    const after = glsl[sw..];
    var hits: usize = 0;
    for ([_][]const u8{ "vec2(0.25", "vec2(0.5", "vec2(0.75" }) |lit| {
        if (std.mem.indexOf(u8, after, lit) != null) hits += 1;
    }
    try std.testing.expect(hits == 3);
}

// #third-switch-site (no-phi path): the same emitBlock switch site also changed shape
// for phi-less switches nested in a selection arm (braced cases, cases-before-default).
// This fixture pins the fallthrough-into-default edge there: case 2 stores 0.75 and
// OpBranches to the DEFAULT label (a SPIR-V fallthrough edge, not the merge), so the
// emitted GLSL must NOT break after case 2 -- it must fall into default, whose 1.0
// store wins (a wrongly-added break would render 0.75 for sel==2). The old default-
// first order at this site put default before the case, silently dropping the
// fallthrough accumulation.
// Render-verified: z-z round-trip MATCH (NagaCompare sane-64).
const SWITCH_IN_ARM_FALLTHROUGH_SPV = @embedFile("fixtures/switch_in_arm_fallthrough.spv");

test "GLSL keeps fallthrough-into-default for a phi-less switch in a selection arm (#third-switch-site)" {
    const glsl = try crossGlsl(SWITCH_IN_ARM_FALLTHROUGH_SPV);
    defer alloc.free(glsl);
    // case 2 must come BEFORE default and carry NO break (the fallthrough edge).
    const ci = std.mem.indexOf(u8, glsl, "case 2:") orelse return error.MissingCase;
    const di = std.mem.indexOf(u8, glsl, "default:") orelse return error.MissingDefault;
    try std.testing.expect(ci < di);
    const between = glsl[ci..di];
    try std.testing.expect(std.mem.indexOf(u8, between, "break;") == null);
}

// #latch-phi (HLSL port of GLSL's fix/glsl-latch-phi, #613): a continue-block phi
// (latch phi) whose value differs per incoming path got NO copies anywhere in the
// HLSL backend: the loop walker's trivial-continue fast path emitted a bare
// `if (c) continue;`, its branch-to-continue skip dropped the rest silently, and
// emitBlock's switch-case/nested-if continue emitted a bare `continue;`. The
// loop-header carry (`v42 = v83_phi;`) then read an UNINITIALIZED carrier every
// iteration (graphicsfuzz_003 = this fixture: all three accumulators diverged in
// the round-trip render). HLSL declares the carrier (`float3 v83_phi;`) via the
// carried-phi pass but nothing ever wrote it. Assert the latch phi is WRITTEN on
// both paths of the tail selection: the continue arm's copy and the fall-through's
// copy must BOTH exist.
test "HLSL writes the latch phi on both paths of a tail continue (#latch-phi)" {
    const hlsl = try crossHlsl(LATCH_PHI_CONTINUE_SPV);
    defer alloc.free(hlsl);
    // The continue arm's copy and the fall-through's copy must BOTH exist.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "v83_phi = v42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "v83_phi = v244_phi;") != null);
}

// #latch-phi (HLSL, emitBlock site): the same gap through emitBlock -- a switch
// case that branches straight to the enclosing loop's continue emitted a bare
// `continue;` with no latch-phi copies, so the loop-header carry read an
// uninitialized carrier whenever the case fired. Fixture (glslang + spirv-opt -O
// of a `switch (i) { case 0: acc += 1.0; continue; case 1: acc += 2.0; continue;
// default: break; }` loop) has a 3-incoming divergent latch phi (%57) at the
// continue block: both case arms continue via emitBlock, the post-switch
// fall-through via the walker's branch-to-continue skip. All three copies must
// exist (baseline emitted none -- silent-wrong).
const LATCH_PHI_SWITCH_CONTINUE_SPV = @embedFile("fixtures/latch_phi_switch_continue.spv");

test "HLSL writes the latch phi on a switch-case continue (#latch-phi)" {
    const hlsl = try crossHlsl(LATCH_PHI_SWITCH_CONTINUE_SPV);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "v57_phi = v12;") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "v57_phi = v13;") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "v57_phi = v16;") != null);
}
