#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test GLSL cubic interpolation
vec4 cubic(float v) {
    vec4 n = vec4(1.0, 2.0, 3.0, 4.0) - v;
    vec4 s = n * n * n;
    float x = s.x;
    float y = s.y - 4.0 * s.x;
    float z = s.z - 4.0 * s.y + 6.0 * s.x;
    float w = 6.0 - x - y - z;
    return vec4(x, y, z, w) / 6.0;
}

void main() {
    vec4 c = cubic(uv.x * 3.0);
    float val = dot(c, vec4(0.2, 0.4, 0.6, 0.8));
    
    vec3 col = vec3(val, val * uv.y, 1.0 - val);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
