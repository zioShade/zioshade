// Tests: integer/uint-base multi-component swizzle compound-assignment (#170).
// GLSL `ivec.xy += ivec2` / `uvec.xy *= uvec2` / `uvec.xy /= uvec2` are valid,
// but glslpp's swizzle compound-assign path emitted the FLOAT op tags
// (OpFAdd/OpFMul/OpFDiv) unconditionally → invalid SPIR-V on integer operands
// ("Expected floating scalar or vector type"). The op must be the INTEGER form
// (OpIAdd/OpIMul/OpISub/OpSDiv — the project's `.div` tag emits OpSDiv for both
// signed and unsigned, same as the plain compound-assign and binary paths).
#version 450
layout(location = 0) flat in ivec2 si;
layout(location = 1) flat in uvec2 su;
layout(location = 2) flat in int ss;
layout(location = 0) out vec4 o;

void main() {
    ivec4 a = ivec4(8);
    a.xy += si;     // OpIAdd, not OpFAdd
    a.xy *= si;     // OpIMul, not OpFMul
    a.zw += ss;     // scalar splat then OpIAdd

    uvec4 b = uvec4(16u);
    b.xy /= su;     // OpUDiv, not OpFDiv
    b.zw -= su;     // OpISub, not OpFSub

    o = vec4(a) + vec4(b);
}
