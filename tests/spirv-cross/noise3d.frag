#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test 3D noise via 2D slices
float hash(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float noise3d(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    
    float a = hash(i);
    float b = hash(i + vec3(1, 0, 0));
    float c = hash(i + vec3(0, 1, 0));
    float d = hash(i + vec3(1, 1, 0));
    float e = hash(i + vec3(0, 0, 1));
    float ff = hash(i + vec3(1, 0, 1));
    float g = hash(i + vec3(0, 1, 1));
    float h = hash(i + vec3(1, 1, 1));
    
    float x1 = mix(a, b, f.x);
    float x2 = mix(c, d, f.x);
    float x3 = mix(e, ff, f.x);
    float x4 = mix(g, h, f.x);
    
    float y1 = mix(x1, x2, f.y);
    float y2 = mix(x3, x4, f.y);
    
    return mix(y1, y2, f.z);
}

void main() {
    vec3 p = vec3(uv * 3.0, 0.5);
    float n = noise3d(p);
    
    vec3 col = vec3(n * 0.8, n * 0.6, n * 0.3);
    fragColor = vec4(col, 1.0);
}
