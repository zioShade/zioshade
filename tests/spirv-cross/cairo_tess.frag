#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Tessellation of interlocking shapes
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // Cairo pentagonal tiling approximation
    float d1 = f.x + f.y * 0.5;
    float d2 = (1.0 - f.x) + f.y * 0.5;
    float d3 = f.x * 0.5 + f.y;
    float d4 = (1.0 - f.x) * 0.5 + f.y;
    float mind = min(min(d1, d2), min(d3, d4));
    float edge = smoothstep(0.02, 0.01, abs(mind - 0.5));
    vec3 col_a = vec3(0.2, 0.5, 0.6);
    vec3 col_b = vec3(0.6, 0.3, 0.4);
    vec3 col = h < 0.5 ? col_a : col_b;
    col = mix(col, vec3(0.1), edge * 0.5);
    fragColor = vec4(col, 1.0);
}
