#version 310 es
precision highp float;
out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
        mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
        f.y
    );
}

float fbm(vec2 p) {
    float f = 0.0;
    float a = 0.5;
    for (int i = 0; i < 6; i++) {
        f += a * noise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return f;
}

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    float n = fbm(uv + fbm(uv + fbm(uv)));
    vec3 col = mix(vec3(0.1, 0.2, 0.4), vec3(0.9, 0.7, 0.3), n);
    fragColor = vec4(col, 1.0);
}
