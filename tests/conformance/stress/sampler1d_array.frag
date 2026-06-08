#version 450
// #197: sampler1DArray must lower to OpTypeImage 1D Arrayed=1 (not 2D), with the
// Sampled1D capability. Covers float/int/uint 1D + 1D-array via texture/texelFetch/
// textureSize; all results flow to the output so the image ops escape DCE.
layout(location = 0) out vec4 o;
layout(location = 0) flat in vec2 c;

layout(binding = 0) uniform sampler1D       s1;
layout(binding = 1) uniform sampler1DArray  sa;
layout(binding = 2) uniform isampler1DArray ia;
layout(binding = 3) uniform usampler1DArray ua;

void main() {
    vec4 a = texture(s1, c.x) + texelFetch(s1, int(c.x), 0);
    vec4 b = texture(sa, c) + texelFetch(sa, ivec2(c), 0) + vec4(textureSize(sa, 0), 0.0, 0.0);
    vec4 d = vec4(texelFetch(ia, ivec2(c), 0)) + vec4(textureSize(ia, 0), 0, 0);
    vec4 e = vec4(texelFetch(ua, ivec2(c), 0)) + vec4(textureSize(ua, 0), 0, 0);
    o = a + b + d + e;
}
