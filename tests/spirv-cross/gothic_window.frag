#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Gothic arch window
    vec3 col = vec3(0.3, 0.4, 0.6); // sky through window
    // Window frame
    vec2 p = uv - vec2(5.0, 5.0);
    // Arch: pointed top
    float arch_top = smoothstep(0.02, 0.01, abs(p.y - 3.0)) * step(0.0, p.y) * step(abs(p.x), 2.0);
    // Pointed arch
    float arch_r = length(vec2(abs(p.x) - 2.0, max(p.y - 1.0, 0.0)));
    float arch_curve = smoothstep(0.02, 0.01, abs(arch_r - 2.0)) * step(0.0, p.y) * step(p.y, 3.0);
    // Side pillars
    float pillar_l = smoothstep(0.02, 0.01, abs(p.x + 2.0)) * step(-2.0, p.y);
    float pillar_r = smoothstep(0.02, 0.01, abs(p.x - 2.0)) * step(-2.0, p.y);
    float bottom = smoothstep(0.02, 0.01, abs(p.y + 2.0)) * step(abs(p.x), 2.0);
    float frame = max(max(max(arch_curve, arch_top), pillar_l + pillar_r), bottom);
    // Stone color
    vec3 stone = vec3(0.5, 0.48, 0.45);
    col = mix(col, stone, min(frame, 1.0));
    // Tracery (simple cross)
    float cross_h = smoothstep(0.015, 0.008, abs(p.x)) * step(-2.0, p.y) * step(p.y, 2.0);
    float cross_v = smoothstep(0.015, 0.008, abs(p.y)) * step(abs(p.x), 2.0);
    col = mix(col, stone, min(cross_h + cross_v, 1.0) * 0.5);
    fragColor = vec4(col, 1.0);
}
