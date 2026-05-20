#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // L-system tree (recursive branches)
    float trunk = smoothstep(0.02, 0.01, abs(uv.x)) * step(-0.8, uv.y) * step(uv.y, 0.0);
    // Branches (two levels)
    float branches = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float angle = 0.4 + fi * 0.2;
        float side = mod(fi, 2.0) > 0.5 ? 1.0 : -1.0;
        vec2 dir = vec2(side * sin(angle), cos(angle));
        vec2 base = vec2(0.0, -0.2 + fi * 0.25);
        float proj = dot(uv - base, dir);
        float perp = abs(dot(uv - base, vec2(-dir.y, dir.x)));
        float thick = 0.012 / (fi * 0.3 + 1.0);
        float branch = smoothstep(thick, thick * 0.5, perp) * step(0.0, proj) * step(proj, 0.5);
        branches += branch;
    }
    float tree = min(trunk + branches, 1.0);
    vec3 col = vec3(0.6, 0.8, 0.95);
    col = mix(col, vec3(0.35, 0.2, 0.08), trunk);
    col = mix(col, vec3(0.15, 0.4, 0.1), branches);
    // Ground
    col = mix(col, vec3(0.3, 0.5, 0.2), step(uv.y, -0.8));
    fragColor = vec4(col, 1.0);
}
