#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Penrose tiling approximation (fat/rhombus)
    float scale = 5.0;
    vec2 p = uv * scale;
    // Five-fold symmetry via projection
    float angles[5];
    angles[0] = 0.0;
    angles[1] = 1.2566;
    angles[2] = 2.5132;
    angles[3] = 3.7699;
    angles[4] = 5.0265;
    float min_d = 100.0;
    for (int i = 0; i < 5; i++) {
        float a = angles[i];
        vec2 dir = vec2(cos(a), sin(a));
        float proj = dot(p, dir);
        float stripe = abs(fract(proj) - 0.5);
        min_d = min(min_d, stripe);
    }
    float tile = smoothstep(0.1, 0.08, min_d);
    vec3 col = vec3(0.15, 0.2, 0.3) + vec3(0.6, 0.5, 0.3) * tile;
    fragColor = vec4(col, 1.0);
}
