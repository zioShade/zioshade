#version 310 es
precision highp float;
out vec4 fragColor;

// Recursive-like pattern: function calling another function that uses its result
float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
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
    vec2 uv = gl_FragCoord.xy / 300.0;
    float h = terrain(uv * 4.0);

    vec3 col = mix(vec3(0.2, 0.5, 0.2), vec3(0.8, 0.6, 0.3), h);
    if (h > 0.6) col = vec3(0.95, 0.95, 1.0);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
