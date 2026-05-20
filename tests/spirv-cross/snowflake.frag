#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Ice crystal / snowflake
    vec3 col = vec3(0.05, 0.08, 0.15);
    float r = length(uv - vec2(5.0, 5.0));
    float a = atan(uv.y - 5.0, uv.x - 5.0);
    // 6-fold symmetry
    float sa = mod(a, 1.0472);
    sa = abs(sa - 0.5236);
    // Branch arms
    float arm = smoothstep(0.02, 0.01, sa * r) * step(0.3, r) * step(r, 4.0);
    // Side branches
    float branch_r = r - 1.5;
    float branch = smoothstep(0.02, 0.01, abs(sa * 3.0 - 0.3)) * step(0.0, branch_r) * step(branch_r, 1.5);
    // Center hex
    float hex = smoothstep(0.6, 0.55, r);
    col += vec3(0.6, 0.8, 1.0) * (arm + branch + hex * 0.3);
    fragColor = vec4(col, 1.0);
}
