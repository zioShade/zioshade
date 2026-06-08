#version 450
// Nested arrays of 1D samplers must still declare the Sampled1D capability.
// The capability detector must unwrap EVERY array level, not just one: a
// single-level unwrap left `uniform sampler1D s[..][..]` emitting a Dim=1D
// OpTypeImage with no Sampled1D capability, so spirv-val rejected the module
// ("Operand 3 of TypeImage requires ... Sampled1D"). Results flow to the output
// so the sample ops escape DCE.
layout(location = 0) out vec4 o;
layout(location = 0) flat in float c;

layout(binding = 0) uniform sampler1D s[2][2];

void main() {
    o = texture(s[0][1], c) + texture(s[1][0], c);
}
