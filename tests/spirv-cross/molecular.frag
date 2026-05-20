#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // Molecular bonds (atoms with bonds)
    vec3 col = vec3(0.02, 0.02, 0.05);
    // Atoms at various positions
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        vec2 pos = vec2(
            fract(sin(fi * 127.1) * 43758.5) * 12.0 + 2.0,
            fract(sin(fi * 311.7) * 43758.5) * 12.0 + 2.0
        );
        float d = length(uv - pos);
        // Electron cloud
        float cloud = exp(-d * d * 8.0) * 0.4;
        float nucleus = smoothstep(0.15, 0.08, d);
        vec3 atom_col = vec3(
            fract(sin(fi * 74.3) * 43758.5),
            fract(sin(fi * 51.7) * 43758.5),
            fract(sin(fi * 93.1) * 43758.5)
            ) * 0.5 + 0.5;
        col += atom_col * cloud;
        col += atom_col * nucleus * 0.8;
    }
    fragColor = vec4(col, 1.0);
}
