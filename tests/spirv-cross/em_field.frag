#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Electromagnetic field lines
    vec2 p1 = vec2(3.0, 4.0);
    vec2 p2 = vec2(9.0, 4.0);
    vec2 r1 = uv - p1;
    vec2 r2 = uv - p2;
    float d1 = length(r1);
    float d2 = length(r2);
    // Field direction (superposition of two charges)
    vec2 field = r1 / (d1 * d1 + 0.1) - r2 / (d2 * d2 + 0.1);
    float f_len = length(field);
    // Field lines as texture
    float lines = sin(atan(field.y, field.x) * 12.0) * 0.5 + 0.5;
    float intensity = 1.0 / (f_len * 20.0 + 1.0);
    vec3 col = vec3(0.2, 0.5, 0.9) * lines * intensity;
    // Charge markers
    col += vec3(1.0, 0.2, 0.2) * smoothstep(0.15, 0.1, d1);
    col += vec3(0.2, 0.2, 1.0) * smoothstep(0.15, 0.1, d2);
    fragColor = vec4(col, 1.0);
}
