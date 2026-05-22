#version 310 es
precision highp float;
out vec4 fragColor;

float sdCircle(vec2 p, float r) {
    return length(p) - r;
}

float sdBox(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float smoothUnion(float d1, float d2, float k) {
    float h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    return mix(d2, d1, h) - k * h * (1.0 - h);
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float d1 = sdCircle(uv - vec2(0.35), 0.2);
    float d2 = sdBox(uv - vec2(0.65), vec2(0.15));
    float d = smoothUnion(d1, d2, 0.05);

    vec3 col = vec3(1.0) - vec3(smoothstep(0.0, 0.01, d));
    col *= 1.0 - exp(-3.0 * abs(d));
    col *= 0.8 + 0.2 * cos(32.0 * d);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
