#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Golden spiral
    float golden = 2.399963; // golden angle in radians
    float spiral_r = sqrt(r) * 10.0;
    float spiral_a = mod(a - spiral_r, golden);
    float dot_size = 0.02 / (r + 0.1);
    float d = abs(spiral_a);
    float dot = smoothstep(dot_size, dot_size * 0.5, d);
    dot *= step(0.05, r) * (1.0 - step(1.0, r));
    vec3 col = vec3(0.9, 0.75, 0.3) * dot + vec3(0.05) * (1.0 - dot);
    fragColor = vec4(col, 1.0);
}
