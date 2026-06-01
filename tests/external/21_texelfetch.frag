#version 450
// Regression guard: texelFetch lowers to WGSL textureLoad, which REQUIRES a 3rd
// arg — the mip level (sampled) / sample index (MS). glslpp previously emitted
// textureLoad(t, coord) (2 args), which naga rejects.
layout(binding = 0) uniform sampler2D t;
layout(location = 0) out vec4 o;

void main() {
    o = texelFetch(t, ivec2(gl_FragCoord.xy), 0);
}
