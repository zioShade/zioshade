#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test hash-based noise without textures
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void main() {
    float n = noise(uv * 8.0);
    float n2 = noise(uv * 16.0 + 5.0);
    
    vec3 col = vec3(n * 0.7, n2 * 0.3 + 0.2, n * n2);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
