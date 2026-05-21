#version 310 es
precision highp float;
out vec4 fragColor;

// Test: nested function calls 3 levels deep
float hash4(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5); }
float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = hash4(i);
    float b = hash4(i + vec2(1.0, 0.0));
    float c = hash4(i + vec2(0.0, 1.0));
    float d = hash4(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float terrain(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        val += amp * valueNoise(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float h = terrain(uv * 4.0);
    vec3 col = mix(vec3(0.2, 0.4, 0.15), vec3(0.6, 0.5, 0.3), h);
    col *= 0.7 + 0.3 * smoothstep(0.4, 0.6, h);
    fragColor = vec4(col, 1.0);
}
