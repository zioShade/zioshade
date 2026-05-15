#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test mixed type chains
    int a = int(uv.x * 10.0);
    uint b = uint(a);
    float c = float(b) / 10.0;

    // Test ivec operations
    ivec2 d = ivec2(uv * 5.0);
    ivec2 e = d + ivec2(1, 2);
    vec2 f = vec2(e) / 5.0;

    // Test uvec operations
    uvec2 g = uvec2(e);
    uvec2 h = g & uvec2(7u, 15u);
    vec2 i = vec2(h) / 15.0;

    fragColor = vec4(c, f.x, i.y, 1.0);
}
