#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Nerve cell / neuron
    vec3 col = vec3(0.02, 0.02, 0.06);
    // Cell body (soma)
    float soma = smoothstep(0.6, 0.4, length(uv - vec2(5.0, 5.0)));
    col += vec3(0.4, 0.5, 0.8) * soma;
    // Axon (main branch)
    float axon = smoothstep(0.04, 0.02, abs(uv.y - 5.0 - sin(uv.x - 5.0) * 0.3)) * step(5.5, uv.x);
    col += vec3(0.3, 0.4, 0.7) * axon;
    // Dendrites (branching from soma)
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float angle = fi * 1.047 + 0.5;
        vec2 dir = vec2(cos(angle), sin(angle));
        float proj = dot(uv - vec2(5.0, 5.0), dir);
        float perp = abs(dot(uv - vec2(5.0, 5.0), vec2(-sin(angle), cos(angle))));
        float width = 0.04 * (1.0 - proj * 0.15);
        float dendrite = smoothstep(width, width * 0.5, perp) * step(0.0, proj) * step(proj, 2.0);
        col += vec3(0.4, 0.6, 0.9) * dendrite;
    }
    // Synaptic terminals (dots at axon end)
    col += vec3(0.8, 0.3, 0.3) * smoothstep(0.08, 0.05, length(uv - vec2(10.0, 4.5)));
    fragColor = vec4(col, 1.0);
}
