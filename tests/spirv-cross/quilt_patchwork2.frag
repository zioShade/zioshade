#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    float scale = 2.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    vec3 col;
    if (h < 0.25) {
        col = vec3(0.8, 0.3, 0.3);
    } else if (h < 0.5) {
        float check = step(0.5, fract(f.x * 3.0)) * step(0.5, fract(f.y * 3.0));
        check += step(0.5, fract(f.x * 3.0 + 0.5)) * step(0.5, fract(f.y * 3.0 + 0.5));
        col = mix(vec3(0.6, 0.5, 0.3), vec3(0.9, 0.85, 0.7), check);
    } else if (h < 0.75) {
        col = vec3(0.3, 0.6, 0.3);
    } else {
        float edge = min(min(f.x, 1.0-f.x), min(f.y, 1.0-f.y));
        col = mix(vec3(0.3, 0.6, 0.3), vec3(0.2, 0.4, 0.2), smoothstep(0.1, 0.05, edge));
    }
    fragColor = vec4(col, 1.0);
}
