#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test nested function calls with multiple return paths
float noise(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float fbm(vec2 p) {
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        sum += noise(p) * amp;
        p *= 2.0;
        amp *= 0.5;
    }
    return sum;
}

float pattern(vec2 p) {
    float n1 = fbm(p);
    float n2 = fbm(p + vec2(n1 * 3.0));
    return n2;
}

void main() {
    float val = pattern(uv * 3.0);
    vec3 col = vec3(val, val * 0.7, val * 0.4);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
