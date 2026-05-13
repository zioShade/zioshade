test "T24.2c: debug HLSL loop output" {
    const source =
        \#version 430
        \layout(binding = 0, std140) uniform U { int n; float x; } u;
        \void main() {
        \    float sum = 0.0;
        \    for (int i = 0; i < u.n; i++) {
        \        sum += u.x;
        \        if (sum > 10.0) break;
        \    }
        \    if (sum > 0.0) discard;
        \}
    ;
    const spirv = try compileToSpirv(source);
    defer alloc.free(spirv);
    // Check if SPIR-V has LoopMerge
    var has_loop = false;
    for (spirv) |word| {
        if ((word & 0xFFFF) == @intFromEnum(glslpp.spirv.Op.LoopMerge)) {
            has_loop = true;
        }
    }
    try std.testing.expect(has_loop);

    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try std.testing.expect(hlsl.len > 0);
    // Just print and check we get output
    try assertContains(hlsl, "discard");
}
