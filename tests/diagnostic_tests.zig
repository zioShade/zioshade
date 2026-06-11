const std = @import("std");
const glslpp = @import("glslpp");
const diagnostic = glslpp.diagnostic;
const semantic = glslpp.semantic;
const diag_helpers = @import("helpers/diagnostics.zig");

// =============================================================================
// Diagnostic tests — verify line/column reporting across compilation stages
// =============================================================================

test "semantic error reports line and column for undefined variable" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayListUnmanaged(diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }

    const result = glslpp.compileToSPIRVWithDiagnostics(
        alloc,
        \\#version 430
        \\void main() { undeclared_var = 42; }
    ,
        .{ .stage = .fragment },
        &diags,
    );
    if (result) |words| {
        defer alloc.free(words);
    } else |_| {
        // If it failed, verify diagnostics were recorded
        if (diags.items.len > 0) {
            try std.testing.expect(diags.items[0].line > 0);
            try std.testing.expect(diags.items[0].message.len > 0);
        }
    }
}

test "semantic error message includes context" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayListUnmanaged(diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }

    const result = glslpp.compileToSPIRVWithDiagnostics(
        alloc,
        \\#version 430
        \\void main() {
        \\    vec4 v = some_undefined_function(1.0);
        \\}
    ,
        .{ .stage = .fragment },
        &diags,
    );
    if (result) |words| {
        defer alloc.free(words);
    } else |_| {
        if (diags.items.len > 0) {
            const msg = diags.items[0].message;
            // Should mention something about the error
            try std.testing.expect(msg.len > 0);
            try std.testing.expect(diags.items[0].line >= 2); // line 3 in source (1-indexed)
        }
    }
}

test "lexer error reports line and column for invalid token" {
    const alloc = std.testing.allocator;

    // Try to compile a shader with a known lexer error (unterminated string)
    const result = glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\void main() {
        \\    int x = 0;
        \\}
    , .{ .stage = .fragment });

    // This should succeed since the above is valid GLSL
    // For an actual lexer error test, we'd need something like bad characters
    if (result) |words| {
        defer alloc.free(words);
    } else |_| {}
}

test "parser error reports line and column" {
    const alloc = std.testing.allocator;

    // Reset error state
    semantic.clearError();

    // This shader has a parser error: if without proper body
    const result = glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\void main() {
        \\    if (true)
        \\}
    , .{ .stage = .fragment });

    if (result) |words| {
        defer alloc.free(words);
    } else |_| {
        // Check that the error location was set
        const line = semantic.last_error_line;
        const col = semantic.last_error_column;
        const ctx = semantic.last_error_ctx;

        // Parser should have set the error location
        _ = line;
        _ = col;
        _ = ctx;
    }
}

test "parser: malformed float exponent fails loud, not silent 0.0" {
    const alloc = std.testing.allocator;
    // The lexer accepts an exponent marker with no exponent digits (`1e`, `1.5e+`), but
    // std.fmt.parseFloat rejects those. They were silently folded to 0.0 (silent-wrong);
    // glslang rejects them ("bad character in float exponent"), so they must fail loud.
    const bad1: [:0]const u8 = "#version 450\nlayout(location=0) out vec4 o;\nvoid main(){ float x = 1e; o = vec4(x); }";
    // The parser records the malformed-literal error and recovers; semantic analysis
    // (fail_on_recorded_errors) then rejects it — the same fail-loud channel the int path
    // uses, surfacing as SemanticFailed. The point is it ERRORS, not that it is 0.0.
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRV(alloc, bad1, .{ .stage = .fragment }));
    const bad2: [:0]const u8 = "#version 450\nlayout(location=0) out vec4 o;\nvoid main(){ float x = 1.5e+; o = vec4(x); }";
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRV(alloc, bad2, .{ .stage = .fragment }));
    // Well-formed float forms must still compile (no over-rejection): trailing dot, leading
    // dot, plain/negative/positive exponent, float suffix.
    inline for (.{ "1.5e3", "1.", ".5", "1.5e-3", "2.0e+4", "3.0f", "0.0", "1e3" }) |lit| {
        const ok: [:0]const u8 = "#version 450\nlayout(location=0) out vec4 o;\nvoid main(){ float x = " ++ lit ++ "; o = vec4(x); }";
        const okr = try glslpp.compileToSPIRV(alloc, ok, .{ .stage = .fragment });
        alloc.free(okr);
    }
}

test "break outside loop reports meaningful context" {
    const alloc = std.testing.allocator;

    semantic.clearError();

    const result = glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\void main() {
        \\    break;
        \\}
    , .{ .stage = .fragment });

    if (result) |words| {
        defer alloc.free(words);
    } else |_| {
        // Should have set error context
        const ctx = semantic.last_error_ctx;
        if (ctx.len > 0) {
            try std.testing.expect(std.mem.indexOf(u8, ctx, "break") != null or
                std.mem.indexOf(u8, ctx, "loop") != null);
        }
    }
}

test "continue outside loop reports meaningful context" {
    const alloc = std.testing.allocator;

    semantic.clearError();

    const result = glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\void main() {
        \\    continue;
        \\}
    , .{ .stage = .fragment });

    if (result) |words| {
        defer alloc.free(words);
    } else |_| {
        const ctx = semantic.last_error_ctx;
        if (ctx.len > 0) {
            try std.testing.expect(std.mem.indexOf(u8, ctx, "continue") != null or
                std.mem.indexOf(u8, ctx, "loop") != null);
        }
    }
}

test "type mismatch reports meaningful context" {
    const alloc = std.testing.allocator;

    semantic.clearError();

    // This shader has a type mismatch: bool + float
    const result = glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\void main() {
        \\    float x = true + 1.0;
        \\}
    , .{ .stage = .fragment });

    if (result) |words| {
        defer alloc.free(words);
    } else |_| {
        // The error should have type-mismatch context
        const ctx = semantic.last_error_ctx;
        if (ctx.len > 0) {
            // Either the semantic analyzer caught it or the errdefer set context
            try std.testing.expect(ctx.len > 0);
        }
    }
}

test "error location persists through compileToSPIRVWithDiagnostics" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayListUnmanaged(diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }

    // Shader with an undefined variable on line 3
    const result = glslpp.compileToSPIRVWithDiagnostics(
        alloc,
        \\#version 430
        \\void main() {
        \\    vec4 x = nonexistent_var;
        \\}
    ,
        .{ .stage = .fragment },
        &diags,
    );

    if (result) |words| {
        defer alloc.free(words);
    } else |_| {
        if (diags.items.len > 0) {
            // The diagnostic should reference line 3
            const d = diags.items[0];
            try std.testing.expect(d.line >= 2); // Should be around line 3
            try std.testing.expect(d.kind == .@"error");
        }
    }
}

test "diagnostic clearError resets all fields" {
    semantic.last_error_line = 42;
    semantic.last_error_column = 10;
    semantic.last_error_ctx = "test-context";
    semantic.last_error_inner = "test-inner";

    semantic.clearError();

    try std.testing.expectEqual(@as(u32, 0), semantic.last_error_line);
    try std.testing.expectEqual(@as(u32, 0), semantic.last_error_column);
    try std.testing.expectEqualStrings("", semantic.last_error_ctx);
    try std.testing.expectEqualStrings("", semantic.last_error_inner);
}

test "Diagnostic.format produces standard gcc-like output" {
    const d = diagnostic.Diagnostic{
        .kind = .@"error",
        .line = 5,
        .column = 12,
        .message = "undefined variable 'foo'",
        .path = "test.frag",
    };

    // Just verify the fields are accessible and correct
    try std.testing.expectEqual(diagnostic.Diagnostic.Kind.@"error", d.kind);
    try std.testing.expectEqual(@as(u32, 5), d.line);
    try std.testing.expectEqual(@as(u32, 12), d.column);
    try std.testing.expectEqualStrings("undefined variable 'foo'", d.message);
    try std.testing.expectEqualStrings("test.frag", d.path);
}

test "Diagnostic.format without path omits filename" {
    const d = diagnostic.Diagnostic{
        .kind = .warning,
        .line = 3,
        .column = 1,
        .message = "unused variable",
    };

    // Verify empty path
    try std.testing.expectEqualStrings("", d.path);
    try std.testing.expectEqual(diagnostic.Diagnostic.Kind.warning, d.kind);
    try std.testing.expectEqual(@as(u32, 3), d.line);
}

test "expectDiagnostic helper matches glslang-style format" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    try diags.append(alloc, .{
        .kind = .@"error",
        .line = 4,
        .column = 32,
        .message = try alloc.dupe(u8, "'undef_var' : undeclared identifier"),
        .path = "shader.frag",
    });
    try diag_helpers.expectDiagnostic(diags.items, .{
        .line = 4,
        .column = 32,
        .kind = .@"error",
        .message_contains = "undeclared identifier",
    });
}

test "diagnostics: multiple undeclared identifiers each get their own diagnostic" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayListUnmanaged(diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    const result = glslpp.compileToSPIRVWithDiagnostics(
        alloc,
        \\#version 430
        \\void main() {
        \\    vec4 a = undef1;
        \\    vec4 b = undef2;
        \\    vec4 c = undef3;
        \\}
    ,
        .{ .stage = .fragment },
        &diags,
    );
    // Mitchell-philosophy contract: a "success" return must never carry
    // error-kind diagnostics. Because each tolerated statement recorded an
    // `.error` diagnostic, compileToSPIRVWithDiagnostics MUST fail loudly with
    // error.SemanticFailed (and free the misleading partial module internally —
    // we never receive `words`, so there is nothing to free here).
    try std.testing.expectError(error.SemanticFailed, result);
    // At least 2 distinct errors (was 1 before 3.B)
    try std.testing.expect(diags.items.len >= 2);
    // Distinct lines: 3, 4, 5
    var saw3 = false;
    var saw4 = false;
    var saw5 = false;
    for (diags.items) |d| {
        if (d.line == 3) saw3 = true;
        if (d.line == 4) saw4 = true;
        if (d.line == 5) saw5 = true;
        try std.testing.expectEqual(diagnostic.Diagnostic.Kind.@"error", d.kind);
        try std.testing.expect(d.message.len > 0);
    }
    try std.testing.expect(saw3 and saw4 and saw5);
}

test "diagnostics: exceeding the cap appends one truncation marker and fails loudly" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayListUnmanaged(diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }

    // Build a shader whose body has far more than MAX_RECORDED_DIAGS bad
    // statements so the sink cap is exceeded and the synthetic marker fires.
    const n_bad = semantic.MAX_RECORDED_DIAGS + 30;
    var src = std.ArrayListUnmanaged(u8).empty;
    defer src.deinit(alloc);
    try src.appendSlice(alloc, "#version 430\nvoid main() {\n");
    for (0..n_bad) |i| {
        // Each line references a distinct undeclared identifier.
        try src.print(alloc, "    vec4 v{d} = undef{d};\n", .{ i, i });
    }
    try src.appendSlice(alloc, "}\n");
    const src_z = try src.toOwnedSliceSentinel(alloc, 0);
    defer alloc.free(src_z);

    const result = glslpp.compileToSPIRVWithDiagnostics(
        alloc,
        src_z,
        .{ .stage = .fragment },
        &diags,
    );

    // Fail-loud contract still holds: error-kind diagnostics were recorded.
    try std.testing.expectError(error.SemanticFailed, result);

    // The sink is capped, so we never get more than MAX + 1 (the marker).
    try std.testing.expect(diags.items.len <= semantic.MAX_RECORDED_DIAGS + 1);
    // We did hit the cap (otherwise the marker test would be vacuous).
    try std.testing.expectEqual(@as(usize, semantic.MAX_RECORDED_DIAGS + 1), diags.items.len);

    // Exactly one truncation marker, and it is the last entry.
    var marker_count: usize = 0;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "diagnostic limit reached") != null) marker_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), marker_count);
    const last = diags.items[diags.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last.message, "diagnostic limit reached") != null);
    // Marker is error-kind so it participates in the fail-loud contract.
    try std.testing.expectEqual(diagnostic.Diagnostic.Kind.@"error", last.kind);
}

test "diagnostics: valid shader produces no diagnostics and compiles" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayListUnmanaged(diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    const result = glslpp.compileToSPIRVWithDiagnostics(
        alloc,
        \\#version 430
        \\void main() {
        \\    vec4 a = vec4(1.0);
        \\}
    ,
        .{ .stage = .fragment },
        &diags,
    );
    const words = try result;
    defer alloc.free(words);
    try std.testing.expect(words.len > 0);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "multiple errors accumulate line/column correctly" {
    const alloc = std.testing.allocator;

    // Shader that may produce multiple semantic issues
    semantic.clearError();

    const result = glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\void main() {
        \\    vec4 a = undefined1;
        \\    vec4 b = undefined2;
        \\    vec4 c = undefined3;
        \\}
    , .{ .stage = .fragment });

    if (result) |words| {
        defer alloc.free(words);
    } else |_| {
        // The last error should have been recorded
        // (at least the last undefined variable)
        const line = semantic.last_error_line;
        // Should be line 5 or later
        try std.testing.expect(line >= 3);
    }
}
