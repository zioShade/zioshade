#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Gradient through hsv
vec3 hsv2rgb(float h, float s, float v) {
    vec3 c = vec3(h, s, v);
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
    vec3 col = hsv2rgb(uv.x, 0.8, 0.9);
    col *= 0.7 + 0.3 * sin(uv.y * 3.14159);
    fragColor = vec4(col, 1.0);
}
