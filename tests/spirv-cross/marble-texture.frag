#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test marble texture generation
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1,0)), f.x),
               mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), f.x), f.y);
}

void main() {
    float n = noise(uv * 4.0);
    float n2 = noise(uv * 8.0 + 5.0);
    
    // Marble: turbulent distortion of sine wave
    float marble = sin((uv.x + n * 0.5 + n2 * 0.25) * 10.0) * 0.5 + 0.5;
    
    vec3 dark = vec3(0.2, 0.2, 0.25);
    vec3 light = vec3(0.85, 0.85, 0.9);
    vec3 col = mix(dark, light, marble);
    
    fragColor = vec4(col, 1.0);
}
