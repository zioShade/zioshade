#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Lightning / electric arc
    float x = uv.x;
    float bolt = 0.0;
    float y_center = 0.0;
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        y_center += sin(x * (3.0 + fi * 2.0) + fi * 1.7) * 0.08 / (fi + 1.0);
    }
    float d = abs(uv.y - y_center);
    float core = smoothstep(0.01, 0.005, d);
    float glow = smoothstep(0.05, 0.01, d) * 0.4;
    // Branch
    float branch_y = y_center + 0.1 * sin(x * 8.0);
    float branch_d = abs(uv.y - branch_y);
    float branch = smoothstep(0.005, 0.002, branch_d) * step(0.1, x);
    vec3 col = vec3(0.02, 0.02, 0.05);
    col += vec3(0.5, 0.5, 1.0) * glow;
    col += vec3(0.8, 0.8, 1.0) * core;
    col += vec3(0.3, 0.3, 0.8) * branch;
    fragColor = vec4(col, 1.0);
}
