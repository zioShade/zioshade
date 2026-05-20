#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Atoms and bonds (molecular visualization)
    vec3 col = vec3(0.02, 0.02, 0.06);
    // Carbon atoms (6 positions)
    vec2 atoms[6];
    atoms[0] = vec2(0.0, 0.3);
    atoms[1] = vec2(0.3, 0.15);
    atoms[2] = vec2(0.3, -0.15);
    atoms[3] = vec2(0.0, -0.3);
    atoms[4] = vec2(-0.3, -0.15);
    atoms[5] = vec2(-0.3, 0.15);
    // Bonds (lines between adjacent atoms)
    for (int i = 0; i < 6; i++) {
        int j = (i + 1) % 6;
        vec2 a = atoms[i];
        vec2 b = atoms[j];
        vec2 pa = uv - a;
        vec2 ba = b - a;
        float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        float d = length(pa - ba * t);
        float bond = smoothstep(0.01, 0.005, d);
        col += vec3(0.4, 0.4, 0.5) * bond;
    }
    // Atom spheres (shaded circles)
    for (int i = 0; i < 6; i++) {
        float d = length(uv - atoms[i]);
        float sphere = smoothstep(0.06, 0.04, d);
        float shade = sqrt(max(1.0 - d * d * 200.0, 0.0));
        col += vec3(0.2, 0.2, 0.8) * sphere * shade;
    }
    // Center atom (different color)
    float center_d = length(uv);
    col += vec3(0.8, 0.2, 0.2) * smoothstep(0.07, 0.05, center_d) * sqrt(max(1.0 - center_d * center_d * 200.0, 0.0));
    fragColor = vec4(col, 1.0);
}
