#version 450
// Regression guard: a multisampled texture must use WGSL's
// `texture_multisampled_2d<f32>` type name (NOT `texture_2d_multisampled<f32>`,
// which naga rejects). Uses textureSize only (texelFetch on MS textures needs a
// sample-index arg — tracked as a separate follow-up).
layout(binding = 0) uniform sampler2DMS t;
layout(location = 0) out vec4 o;

void main() {
    ivec2 sz = textureSize(t);
    o = vec4(float(sz.x), float(sz.y), 0.0, 1.0);
}
