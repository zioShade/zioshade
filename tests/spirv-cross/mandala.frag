#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Mandala (circular symmetric pattern)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float segments = 12.0;
    float seg_a = 6.2832 / segments;
    float sa = mod(a, seg_a);
    sa = abs(sa - seg_a * 0.5);
    // Concentric rings with different patterns
    float ring1 = smoothstep(0.02, 0.01, abs(r - 0.2));
    float ring2 = smoothstep(0.02, 0.01, abs(r - 0.5));
    float ring3 = smoothstep(0.02, 0.01, abs(r - 0.7));
    // Radial petals
    float petal = smoothstep(0.1, 0.05, sa * r) * step(0.2, r) * step(r, 0.5);
    // Dots at intersections
    float dot_r = 0.2;
    float da = mod(a, seg_a) - seg_a * 0.5;
    float dot_pos = length(vec2(cos(da) * r - dot_r, sin(da) * r));
    float dots = smoothstep(0.02, 0.01, dot_pos);
    vec3 col = vec3(0.1, 0.08, 0.15);
    col += vec3(0.8, 0.6, 0.2) * (ring1 + ring2 + ring3);
    col += vec3(0.6, 0.2, 0.5) * petal;
    col += vec3(0.9, 0.8, 0.3) * dots;
    col *= smoothstep(0.85, 0.8, r);
    fragColor = vec4(col, 1.0);
}
