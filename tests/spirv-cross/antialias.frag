#version 450

// Test: derivative-based anti-aliasing
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 8.0;
    float fw = fwidth(p.x);
    float edge = abs(fract(p.x) - 0.5) * 2.0;
    float line = smoothstep(1.0 - fw * 2.0, 1.0, edge);

    vec3 bg = vec3(0.9);
    vec3 fg = vec3(0.1);
    vec3 col = mix(bg, fg, line);

    gl_FragColor = vec4(col, 1.0);
}
