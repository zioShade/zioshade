#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Nautilus shell (golden spiral)
    float golden = 1.618;
    float a = atan(uv.y, uv.x);
    float r = length(uv);
    float spiral_r = pow(golden, a / 2.4) * 0.05;
    float shell = smoothstep(0.02, 0.015, abs(r - spiral_r));
    float body = step(0.0, r - spiral_r * 0.9) * (1.0 - step(spiral_r * 1.1, r));
    body *= smoothstep(0.0, 0.3, r);
    vec3 col = vec3(0.85, 0.75, 0.6) * body * 0.5;
    col += vec3(0.6, 0.5, 0.4) * shell;
    col += vec3(0.1, 0.15, 0.2) * (1.0 - step(0.9, r));
    fragColor = vec4(col, 1.0);
}
