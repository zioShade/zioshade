#version 310 es
precision highp float;
out vec4 fragColor;

vec3 palette(float t) {
    return 0.5 + 0.5 * cos(6.28 * (t + vec3(0.0, 0.33, 0.67)));
}

float hash21(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    vec2 gv = fract(uv) - 0.5;
    vec2 id = floor(uv);
    float n = hash21(id);
    float size = fract(n * 34.52);
    float d = length(gv) - size * 0.4;
    vec3 col = vec3(0.0);
    col += smoothstep(0.02, 0.0, d) * palette(n);
    fragColor = vec4(col, 1.0);
}
