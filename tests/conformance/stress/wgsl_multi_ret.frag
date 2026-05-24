#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple return paths with different types
vec3 getColor(float t) {
    if (t < 0.33) return vec3(1.0, 0.0, 0.0);
    if (t < 0.66) return vec3(0.0, 1.0, 0.0);
    return vec3(0.0, 0.0, 1.0);
}

float getIntensity(vec2 p) {
    return length(p) * 2.0;
}

void main() {
    vec3 color = getColor(uv.x);
    float intensity = getIntensity(uv);
    color = color * intensity;
    fragColor = vec4(color, 1.0);
}
