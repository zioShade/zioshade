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
const glslpp = @import("glslpp");

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
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 60 });
}

fn compileToGlsl(source: [:0]const u8) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try glslpp.spirvToGLSL(alloc, spirv, .{});
}

fn compileToMsl(source: [:0]const u8) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try glslpp.spirvToMSL(alloc, spirv, .{});
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
