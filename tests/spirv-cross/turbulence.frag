#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test turbulence (fbm with abs) 
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i), hash(i + vec2(1, 0)), f.x),
        mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x),
        f.y
    );
}

float turb(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        val += abs(vnoise(p)) * amp;
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

void main() {
    float t = turb(uv * 4.0);
    vec3 col = vec3(t * 0.8, t * 0.5, t * 0.3);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
