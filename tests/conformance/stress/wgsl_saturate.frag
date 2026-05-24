#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test saturate pattern (clamp to 0..1)
float saturate(float x) {
    return clamp(x, 0.0, 1.0);
}

void main() {
    float s = saturate(uv.x * 2.0 - 0.5);
    float t = saturate(uv.y * 3.0 - 1.0);
    vec3 color = vec3(s, t, s * t);
    fragColor = vec4(color, 1.0);
}
