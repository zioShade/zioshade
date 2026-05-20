#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Wood grain texture
    float grain = sin(uv.y * 60.0 + sin(uv.x * 5.0) * 3.0) * 0.5 + 0.5;
    grain *= 0.8 + 0.2 * sin(uv.y * 8.0);
    // Knot
    vec2 knot_pos = vec2(3.0, 2.5);
    float knot_dist = length(uv - knot_pos);
    float knot = smoothstep(0.5, 0.3, knot_dist);
    float knot_ring = smoothstep(0.1, 0.05, abs(knot_dist - 0.35));
    vec3 wood = mix(vec3(0.6, 0.35, 0.15), vec3(0.4, 0.22, 0.08), grain);
    wood = mix(wood, vec3(0.3, 0.15, 0.05), knot);
    wood = mix(wood, vec3(0.5, 0.3, 0.12), knot_ring);
    fragColor = vec4(wood, 1.0);
}
