#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Planet Saturn with rings
    float r = length(uv);
    // Planet body
    float planet = smoothstep(0.42, 0.4, r);
    vec3 planet_col = vec3(0.85, 0.75, 0.5) * sqrt(max(1.0 - r * r, 0.0));
    // Rings (ellipse)
    float ring_r = length(vec2(uv.x * 0.4, uv.y));
    float ring = smoothstep(0.85, 0.82, ring_r) * (1.0 - smoothstep(0.55, 0.52, ring_r));
    // Gap in rings (Cassini division)
    ring *= 1.0 - smoothstep(0.65, 0.63, ring_r) * (1.0 - smoothstep(0.60, 0.58, ring_r));
    // Front/back ring (planet occludes back part)
    float front_ring = ring * step(0.0, uv.y);
    float back_ring = ring * (1.0 - step(0.0, uv.y)) * (1.0 - planet);
    vec3 ring_col = vec3(0.7, 0.6, 0.45);
    vec3 col = vec3(0.0);
    col += planet_col * planet;
    col += ring_col * (front_ring + back_ring);
    fragColor = vec4(col, 1.0);
}
