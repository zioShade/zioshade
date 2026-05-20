#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Japanese wave pattern (seigaiha)
    float scale = 2.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Concentric arcs from center of each cell
    vec2 center = vec2(0.5, 0.5);
    float d = length(f - center);
    // Multiple concentric arcs
    float arcs = 0.0;
    for (int i = 1; i <= 3; i++) {
        float r_inner = float(i) * 0.12;
        float arc = smoothstep(r_inner + 0.02, r_inner, d) * (1.0 - smoothstep(r_inner - 0.01, r_inner - 0.03, d));
        arcs += arc;
    }
    arcs = min(arcs, 1.0);
    vec3 blue = vec3(0.15, 0.3, 0.6);
    vec3 white = vec3(0.95, 0.95, 0.95);
    vec3 col = mix(white, blue, arcs);
    fragColor = vec4(col, 1.0);
}
