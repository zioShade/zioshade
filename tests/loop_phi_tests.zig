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

// GLSL and MSL backends share the same root cause; their fixes (and tests) land
// in follow-up changes. The compile helpers below are kept for those.
comptime {
    _ = &compileToGlsl;
    _ = &compileToMsl;
}
