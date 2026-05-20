#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Coulomb potential (two charges)
    float q1 = 1.0;
    float q2 = -1.0;
    vec2 p1 = vec2(-0.4, 0.0);
    vec2 p2 = vec2(0.4, 0.0);
    float r1 = length(uv - p1);
    float r2 = length(uv - p2);
    float v = q1 / (r1 + 0.05) + q2 / (r2 + 0.05);
    // Map potential to color
    float positive = max(v, 0.0);
    float negative = max(-v, 0.0);
    vec3 col = vec3(positive * 0.3, 0.1, negative * 0.3);
    // Equipotential lines
    float eq = fract(v * 2.0);
    float line = smoothstep(0.04, 0.01, min(eq, 1.0 - eq));
    col += vec3(0.4) * line;
    fragColor = vec4(col, 1.0);
}
