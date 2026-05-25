// Tests: image load/store (storage image)
#version 450
layout(binding = 0, rgba8) uniform image2D img;

void main() {
    ivec2 coord = ivec2(gl_FragCoord.xy);
    vec4 existing = imageLoad(img, coord);
    vec4 color = existing * 0.5 + vec4(0.1);
    imageStore(img, coord, color);
}
