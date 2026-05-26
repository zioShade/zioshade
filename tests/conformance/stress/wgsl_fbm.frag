// Test: noise-like pattern with many math ops
#version 450

layout(location = 0) out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);  // smoothstep
    
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    float freq = 1.0;
    for (int i = 0; i < 6; i++) {
        val += amp * noise(p * freq);
        freq *= 2.0;
        amp *= 0.5;
    }
    return val;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float n1 = fbm(uv * 4.0);
    float n2 = fbm(uv * 4.0 + vec2(5.2, 1.3));
    float n3 = fbm(vec2(n1, n2) * 3.0);
    
    vec3 color = mix(vec3(0.1, 0.2, 0.5), vec3(0.8, 0.6, 0.2), n3);
    fragColor = vec4(color, 1.0);
}
