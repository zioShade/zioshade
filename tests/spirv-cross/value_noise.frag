#version 450

// Test: multi-layer noise approximation
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
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float n1 = noise(uv * 4.0);
    float n2 = noise(uv * 8.0);
    float n = n1 * 0.7 + n2 * 0.3;
    gl_FragColor = vec4(vec3(n), 1.0);
}
