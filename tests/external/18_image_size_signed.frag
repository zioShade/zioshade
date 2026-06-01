#version 450
// Regression guard: GLSL imageSize/textureSize return SIGNED int/ivecN, but WGSL
// textureDimensions returns UNSIGNED u32/vecNu. The result must be converted to
// the signed type, else naga rejects ("expected vec2<i32>, got vec2<u32>").
layout(r32f, binding = 0) uniform image2D img;
layout(binding = 1) uniform sampler2D tex;
layout(location = 0) out vec4 o;

void main() {
    ivec2 isz = imageSize(img);       // ivec2 (signed)
    ivec2 tsz = textureSize(tex, 0);  // ivec2 (signed)
    int s = isz.x + isz.y + tsz.x + tsz.y;
    o = vec4(float(s), 0.0, 0.0, 1.0);
}
